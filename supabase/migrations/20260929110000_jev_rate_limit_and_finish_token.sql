-- =============================================================================
-- 44_jev_rate_limit_and_finish_token.sql — AP-69 Review-Funde (2026-09-29),
-- Punkte 86 und 87
--
-- Punkt 86 (Drosselung): jeder Klick auf "KI-Zuordnung pruefen" loeste bisher
-- einen bezahlten OpenRouter-Aufruf ueber app.rpc_squad_check_jev_context aus,
-- ohne jede Begrenzung. Ein Staff-Nutzer konnte das in einer Schleife
-- ausloesen. Fix: bevor eine neue pending-Zeile angelegt wird, prueft die Tuer,
-- ob fuer denselben input_hash (identische Eingaben: Regelversion, Session-
-- Kontext, Kandidatenliste) im selben Team bereits ein Aufruf innerhalb der
-- letzten 5 Minuten existiert (dasselbe Zeitfenster wie das bestehende
-- 5-Minuten-Fenster in app.rpc_finish_model_call). Ist das der Fall, wirft die
-- Tuer RATE_LIMITED (55000, dieselbe Fehlerklasse wie MODULE_DISABLED) statt
-- einen weiteren Aufruf zu erlauben. squadCheckActions.ts faengt JEDEN Fehler
-- aus dieser Tuer ab und faellt auf die Regel v1 zurueck (kein Unterschied zum
-- bestehenden Verhalten bei Schalter aus) -- kein Sonderfall im Frontend
-- noetig. Ein Nutzer, der wiederholt exakt dieselbe Einheit prueft, bekommt
-- innerhalb von 5 Minuten keinen neuen bezahlten Aufruf mehr, unabhaengig
-- davon, ob der vorherige schon beantwortet ist.
--
-- Nachtrag Security-Review (2026-09-29, MITTEL, Punkt 86 trivial umgehbar):
-- die Hash-basierte Drosselung oben hatte drei Luecken.
--   a) v_hash_in flossen p_duration_min/p_planned_intensity ein -- beide vom
--      Client kontrolliert (rpc_squad_check_jev_context ist ueber die
--      public-Tuer fuer jede authenticated Person mit Staff-Rolle erreichbar).
--      Eine Variation dieser zwei Werte erzeugte einen neuen input_hash und
--      damit beliebig viele bezahlte Aufrufe fuer dieselbe Einheit.
--      Root-Fix: die Tuer liest duration_min/planned_intensity jetzt aus der
--      gespeicherten app.training_sessions-Zeile (v_session, ohnehin schon
--      geladen), nicht mehr aus den Parametern. Das ist keine
--      Verhaltensaenderung: SquadCheckPanel/PlanungWorkspace.tsx zeigen den
--      JEV-Button nur, wenn der Entwurf nicht "dirty" ist, und uebergeben in
--      diesem Fall exakt die gespeicherten Werte -- p_duration_min/
--      p_planned_intensity bleiben nur noch aus Kompatibilitaetsgruenden in
--      der Signatur, werden aber nicht mehr fuer Kontext, Hash oder Regel v1
--      benutzt.
--   b) Race Condition zwischen dem EXISTS-Check und dem folgenden INSERT (kein
--      Lock) -- parallele Aufrufe (z.B. Promise.all im Client oder ein
--      direkter PostgREST-Doppelklick) kamen alle durch, weil keiner der
--      beiden Aufrufe die Zeile des anderen schon sehen konnte.
--   c) Die Drosselung war team-weit statt personenbezogen -- ein Nutzer
--      konnte durch einen direkten Aufruf der Kontext-Tuer (ohne echten
--      OpenRouter-Call) den input_hash fuer eine Einheit vorbelegen und damit
--      die KI-Pruefung fuer Kolleginnen im selben Team fuer 5 Minuten
--      blockieren (geringes Risiko, aber ungewollter Nebeneffekt).
-- Fix: die exakte Hash-Pruefung weicht einer zaehlbasierten Drosselung pro
-- Team UND pro Person (max. 5 Aufrufe/5 Minuten, siehe c_rate_limit_* unten),
-- serialisiert ueber pg_advisory_xact_lock(hashtext(team_id || ':' ||
-- person_id)) VOR der Zaehlung -- das schliesst (b), weil zwei parallele
-- Transaktionen auf denselben Lock-Schluessel serialisiert werden, eine
-- wartet, bis die andere committed oder zurueckrollt, und danach ihren
-- eigenen, dann schon erhoehten Zaehlstand sieht. (c) ist geschlossen, weil
-- der Zaehler auf actor_id (die aufrufende Person) filtert, nicht mehr nur
-- auf team_id -- eine Person kann sich nicht mehr gegenseitig aussperren.
-- (a) ist an der Wurzel geschlossen (siehe oben), der Zaehler ist ausserdem
-- unabhaengig vom input_hash und greift deshalb auch dann, wenn irgendein
-- anderer Eingabewert variiert wuerde.
--
-- Punkt 87 (Aufrufprotokoll faelschbar): app.rpc_finish_model_call pruefte
-- bisher nur eigene Person/eigenes Team/pending-Status/5-Minuten-Fenster. Ein
-- Coach mit einem eigenen gueltigen JWT konnte damit theoretisch die Tuer
-- direkt aufrufen (legt eine pending-Zeile an, OHNE dass Next.js je einen
-- echten OpenRouter-Aufruf macht) und die Zeile danach selbst mit
-- result_class='ok' abschliessen -- das Protokoll haette einen erfolgreichen
-- Aufruf belegt, der nie stattfand. Das erweitert keine Rechte (der Coach darf
-- die Tuer ohnehin aufrufen), schwaecht aber die Nachweisfunktion des
-- Protokolls (ADR-019 §3.3 Punkt 5).
--
-- Bewusst KEIN Service-Role-Weg (die naheliegende Alternative): lib/ai/jev.ts
-- haelt explizit fest "Kein NEXT_PUBLIC_, kein Service Role Key (ADR-019
-- §3.3): der Datenbankzugriff laeuft vorher ueber die rollengepruefte Tuer mit
-- dem JWT der anfragenden Person" -- ein Wechsel auf den Service-Role-Key fuer
-- den Finish-Aufruf wuerde genau diese Architekturentscheidung unterlaufen.
-- Stattdessen: ein pro-Aufruf generiertes Token (finish_token, zufaellige
-- uuid), das die Kontext-Tuer beim Anlegen der pending-Zeile erzeugt, in ihrer
-- Rueckgabe an die aufrufende Next.js Server Action mitgibt (NICHT an den
-- Browser -- runJevSquadCheck() in squadCheckActions.ts gibt nur status/
-- overlays an die Oberflaeche zurueck, ctx.finish_token bleibt serverseitig),
-- und das rpc_finish_model_call zusaetzlich zu den bestehenden Pruefungen
-- verifiziert.
--
-- WAS DER finish_token TATSAECHLICH SCHUETZT (Kommentar-Korrektur, Security-
-- Review 2026-09-29 -- die vorherige Fassung dieses Absatzes war ungenau):
-- der finish_token schuetzt die ERGEBNIS-INTEGRITAET eines Aufrufs, der
-- tatsaechlich ueber die App gelaufen ist. Ohne ihn koennte jemand eine
-- erratene oder beobachtete eigene call_id (z.B. aus einer frueheren, echten
-- Sitzung) direkt per rpc_finish_model_call mit einem frei gewaehlten
-- result_class abschliessen, OHNE dass dieser konkrete Abschluss von einem
-- echten OpenRouter-Aufruf abhinge. Der finish_token bindet den Abschluss an
-- die EINE Kontext-Antwort, aus der er stammt.
--
-- WAS DER finish_token NICHT SCHUETZT (das eigentliche Hauptszenario der
-- Review): ein Coach mit gueltigem JWT kann app.rpc_squad_check_jev_context
-- weiterhin DIREKT aufrufen (z.B. per PostgREST, ohne den Next.js Server
-- Action Pfad), bekommt call_id UND finish_token in DERSELBEN Antwort, und
-- schliesst die Zeile danach selbst mit result_class='ok' ab -- ohne dass je
-- ein echter OpenRouter-Aufruf stattfand. Der Token hilft hier nicht, weil er
-- im selben Aufruf mitgeliefert wird, der die Zeile ueberhaupt erst anlegt:
-- er schuetzt gegen eine gefaelschte ANTWORT auf einen echten App-Aufruf,
-- nicht gegen die FAELSCHUNG der Existenz eines App-Aufrufs selbst
-- (Phantom-Zeilen). Das erweitert keine Rechte (der Coach darf die Tuer
-- ohnehin aufrufen), schwaecht aber die Nachweisfunktion des Protokolls
-- (ADR-019 §3.3 Punkt 5) -- ein Phantom-Aufruf sieht im Protokoll wie ein
-- echter aus.
--
-- FIX (Punkt 87, Nachtrag 2026-09-29): app.rpc_squad_check_jev_context
-- verlangt jetzt zusaetzlich ein Server-Secret (p_context_secret), das
-- Next.js aus der serverseitigen Umgebungsvariable JEV_CONTEXT_SECRET
-- durchreicht (nie NEXT_PUBLIC_, nie an den Browser). Die Tuer prueft es
-- gegen einen in app.jev_context_secret hinterlegten sha256-Hash (siehe
-- Abschnitt 2b unten) und lehnt ohne oder mit falschem Secret komplett ab,
-- BEVOR irgendeine Zeile angelegt wird. Ein direkter Browser- oder
-- PostgREST-Aufruf kennt das Secret nicht und scheitert deshalb schon an der
-- Tuer -- das schliesst die Phantom-Zeilen-Luecke. KEIN Service-Role-Key: das
-- Secret ist ein eigens fuer diesen einen Zweck erzeugter Wert ohne jede
-- Datenbank-Rechteerweiterung, die Tuer prueft weiterhin Rolle/Team/Schalter
-- wie zuvor -- vereinbar mit ADR-019 §3.3 (verboten ist eine
-- Datenbankverbindung/service_role/SQL-Werkzeug FUER DAS MODELL bzw. den
-- Modell-aufrufenden Prozess, nicht ein zusaetzliches Aufrufgeheimnis fuer
-- eine ohnehin rollengepruefte Tuer). Offene Grenze, ehrlich benannt: wer
-- sowohl das Secret als auch den kompletten Aufrufpfad kennt (z.B. ein
-- Insider mit Zugriff auf die Next.js Umgebungsvariablen), kann weiterhin
-- Phantom-Zeilen erzeugen -- vollstaendige Haertung dagegen braucht einen
-- Weg ganz ohne Nutzer-JWT (eigener API-Endpunkt ohne Postgres-Rolle
-- "authenticated"), das ist der Zielzustand aus ADR-019 §3.6 fuer den
-- spaeteren TypeSafe-Direktweg, hier bewusst nicht vorgezogen.
--
-- app.rpc_squad_check_jev_context/app.rpc_finish_model_call Rumpf 1:1 aus
-- backend/41_jev_switch_model_call_log.sql. Beide per DROP + CREATE, weil
-- sich beide Signaturen aendern (rpc_finish_model_call: p_finish_token;
-- rpc_squad_check_jev_context, Nachtrag: p_context_secret) -- CREATE OR
-- REPLACE kann die Parameterliste einer Funktion nicht aendern. Die
-- jeweiligen public-Tueren folgen aus demselben Grund.
-- Voraussetzung: 40_squad_check.sql, 41_jev_switch_model_call_log.sql.
-- Idempotent. Tests: backend/44_jev_rate_limit_and_finish_token.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app.model_call_log — finish_token je Zeile
-- -----------------------------------------------------------------------------

ALTER TABLE app.model_call_log
  ADD COLUMN IF NOT EXISTS finish_token uuid NOT NULL DEFAULT gen_random_uuid();

COMMENT ON COLUMN app.model_call_log.finish_token IS
  'Punkt 87 (2026-09-29): pro Aufruf zufaellig erzeugtes Token. app.rpc_squad_check_jev_context '
  'gibt es zusammen mit call_id zurueck, app.rpc_finish_model_call verlangt es zusaetzlich zu '
  'den bestehenden Pruefungen. Kein Leseweg fuer Clients (REVOKE ALL auf der Tabelle besteht '
  'bereits). Siehe backend/44_jev_rate_limit_and_finish_token.sql.';

-- -----------------------------------------------------------------------------
-- 2a. app.jev_context_secret — Server-Secret fuer die Kontext-Tuer (Punkt 87,
--     Nachtrag 2026-09-29). Singleton-Tabelle (id ist immer true), haelt nur
--     den sha256-Hash des Secrets, nie das Secret selbst. Kein sha256 statt
--     pgcrypto crypt()/gen_salt() aus demselben Grund wie beim input_hash
--     oben: Kernfunktion seit PG 11, kein Schema-Unterschied Cloud
--     (extensions) vs. lokale Test-DB (public). Das Secret ist ein
--     hochentropischer, zufaellig erzeugter Wert (keine Passphrase durch
--     Menschen) -- ein ungesalzener Hash ist dafuer ausreichend, ein
--     Woerterbuch-/Rainbow-Table-Angriff ist praktisch ausgeschlossen.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.jev_context_secret (
  id          boolean PRIMARY KEY DEFAULT true CHECK (id),
  secret_hash text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE app.jev_context_secret IS
  'Punkt 87 (Nachtrag 2026-09-29): sha256-Hash des JEV_CONTEXT_SECRET aus der Next.js '
  'Server-Umgebung. Singleton (genau eine Zeile, id=true). Kein Leseweg fuer irgendeine '
  'Postgres-Rolle ausser dem Function-Owner (SECURITY DEFINER). Gesetzt ueber '
  'app.rpc_set_jev_context_secret (nur service_role, einmaliges Ops-Setup, kein Teil des '
  'Anfragepfads -- siehe Kopfkommentar dieser Migration zur ADR-019 §3.3 Abgrenzung).';

REVOKE ALL ON app.jev_context_secret FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app.rpc_set_jev_context_secret(p_secret text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
BEGIN
  -- Laenge willkuerlich, aber grosszuegig: schuetzt nur gegen ein versehentlich
  -- leeres oder trivial kurzes Secret, keine Passwortrichtlinie fuer Menschen
  -- (das Secret wird von einem Generator erzeugt, nicht getippt).
  IF p_secret IS NULL OR length(p_secret) < 20 THEN
    RAISE EXCEPTION 'INVALID: jev_context_secret.length' USING errcode = '22023';
  END IF;

  INSERT INTO app.jev_context_secret (id, secret_hash, updated_at)
  VALUES (true, encode(pg_catalog.sha256(convert_to(p_secret, 'UTF8')), 'hex'), now())
  ON CONFLICT (id) DO UPDATE
    SET secret_hash = excluded.secret_hash,
        updated_at  = excluded.updated_at;
END;
$$;

COMMENT ON FUNCTION app.rpc_set_jev_context_secret(text) IS
  'Ops-Setup, NICHT Teil des Anfragepfads: hinterlegt den sha256-Hash von JEV_CONTEXT_SECRET. '
  'Nur service_role (per Skript mit demselben Wert wie die Next.js Umgebungsvariable, analog '
  'scripts/shred-auth-user.mjs), kein authenticated/anon. Punkt 87, 2026-09-29.';

REVOKE EXECUTE ON FUNCTION app.rpc_set_jev_context_secret(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_set_jev_context_secret(text) TO service_role;

CREATE OR REPLACE FUNCTION app._jev_context_secret_ok(p_secret text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT p_secret IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM app.jev_context_secret s
        WHERE s.id = true
          AND s.secret_hash = encode(pg_catalog.sha256(convert_to(p_secret, 'UTF8')), 'hex')
     );
$$;

COMMENT ON FUNCTION app._jev_context_secret_ok(text) IS
  'Helfer fuer app.rpc_squad_check_jev_context (Punkt 87, 2026-09-29): true nur bei exaktem '
  'Treffer gegen den hinterlegten Hash. Kein direkter Aufrufweg fuer Clients.';

REVOKE EXECUTE ON FUNCTION app._jev_context_secret_ok(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2b. app.rpc_squad_check_jev_context — zaehlbasierte Drosselung pro Person
--     (Punkt 86), duration_min/planned_intensity aus der Session statt vom
--     Client (Punkt 86 Root-Fix), Server-Secret (Punkt 87 Nachtrag) +
--     finish_token in der Rueckgabe (Punkt 87)
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_squad_check_jev_context(uuid, smallint, smallint);
DROP FUNCTION IF EXISTS app.rpc_squad_check_jev_context(uuid, smallint, smallint);

CREATE FUNCTION app.rpc_squad_check_jev_context(
  p_session_id         uuid,
  p_duration_min       smallint,
  p_planned_intensity  smallint,
  p_context_secret     text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  -- Festgeschrieben (ADR-019 §3.2 Reproduzierbarkeit): nie -latest. Next.js
  -- ruft genau das Modell, das hier protokolliert wird.
  c_provider     CONSTANT text    := 'openrouter';
  c_model        CONSTANT text    := 'typesafe/jev-1.13';
  -- Punkt 86 (Nachtrag 2026-09-29): zaehlbasierte Drosselung statt Hash-exakt.
  -- Fenster identisch zum bisherigen (5 Minuten), Obergrenze grosszuegig
  -- bemessen fuer normalen Gebrauch (mehrere unterschiedliche Einheiten kurz
  -- hintereinander pruefen), aber klein genug, um eine Schleife abzuwuergen.
  c_rate_limit_max_calls CONSTANT integer  := 5;
  c_rate_limit_window    CONSTANT interval := interval '5 minutes';
  v_team_id      uuid;
  v_actor_id     uuid;
  v_session      app.training_sessions%rowtype;
  v_rows         jsonb;
  v_ctx          jsonb;
  v_cands        jsonb;
  v_refs         jsonb;
  v_hash_in      jsonb;
  v_hash         text;
  v_count        integer;
  v_recent_calls integer;
  v_call_id      bigint;
  v_finish_token uuid;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  -- Punkt 87 (Nachtrag 2026-09-29): ohne korrektes Server-Secret keine Zeile,
  -- kein Kontext -- schliesst den Phantom-Zeilen-Weg (direkter Aufruf ohne
  -- Next.js). Bewusst VOR jedem weiteren Datenzugriff, siehe Kopfkommentar.
  IF NOT app._jev_context_secret_ok(p_context_secret) THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  v_team_id  := app.auth_team_id();
  v_actor_id := app.auth_person_id();

  IF p_session_id IS NOT NULL THEN
    SELECT * INTO v_session FROM app.training_sessions
     WHERE id = p_session_id AND team_id = v_team_id;
    IF v_session.id IS NULL THEN
      RAISE EXCEPTION 'NOT_FOUND: training_sessions' USING errcode = 'P0002';
    END IF;
  END IF;

  IF NOT app.module_enabled('jev_squad_check_enabled') THEN
    RAISE EXCEPTION 'MODULE_DISABLED' USING errcode = '55000';
  END IF;

  -- Nur gespeicherte Einheiten: ein Entwurf hat keine Einheit, an die ein
  -- Protokolleintrag (context_ref) und ein Wegklick (j1) gebunden werden kann.
  IF p_session_id IS NULL THEN
    RETURN jsonb_build_object('call_id', NULL, 'candidates', '[]'::jsonb, 'refs', '[]'::jsonb);
  END IF;

  -- Punkt 86 Root-Fix (Nachtrag 2026-09-29): duration_min/planned_intensity
  -- kommen jetzt aus der gespeicherten Session, nicht mehr von p_duration_min/
  -- p_planned_intensity (Client-kontrolliert, siehe Kopfkommentar). Die zwei
  -- Parameter bleiben nur noch in der Signatur (Kompatibilitaet mit dem
  -- bestehenden RPC-Aufruf aus squadCheckActions.ts), ihr Wert wird ab hier
  -- nicht mehr gelesen.
  IF v_session.duration_min IS NULL OR v_session.duration_min <= 0 OR v_session.duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: squad_check.duration_min' USING errcode = '22023';
  END IF;

  IF v_session.planned_intensity IS NULL OR v_session.planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: squad_check.planned_intensity' USING errcode = '22023';
  END IF;

  v_rows := app._squad_check_v1(v_team_id, v_session.session_date, v_session.duration_min, v_session.planned_intensity, p_session_id);

  -- Enger Filter: Regel-Vorschlag full aus Quelle rule (kein Spiegel, nicht
  -- eskaliert), mindestens ein aktiver Hinweis h1/h2/h4, j1 nicht weggeklickt.
  -- Pseudonym zufaellig je Aufruf. Breite mindestens zwei Stellen, bei mehr als
  -- 99 Kandidaten entsprechend mehr (lpad schneidet sonst ab -> Doppelungen).
  WITH cand AS (
    SELECT r ->> 'person_id' AS person_id,
           r ->> 'band' AS band,
           r ->> 'load_level' AS load_level,
           r -> 'released_deviation_keys' AS dev_keys
      FROM jsonb_array_elements(v_rows) r
     WHERE r ->> 'suggestion' = 'full'
       AND r ->> 'source' = 'rule'
       -- Code-Review: ohne Band (kein Readiness-Score heute) nicht an JEV. Ein
       -- Platzhalter wie 'unknown' verriete indirekt den Check-in-Status. Fuer
       -- diese Personen gilt die Regel v1 unveraendert.
       AND r ->> 'band' IS NOT NULL
       AND (r -> 'hints') ?| ARRAY['h1','h2','h4']
       AND NOT ((r -> 'dismissed_hints') ? 'j1')
  ),
  numbered AS (
    SELECT cand.*,
           row_number() OVER (ORDER BY random()) AS rn,
           count(*) OVER () AS total
      FROM cand
  ),
  shaped AS (
    SELECT person_id,
           'A' || lpad(rn::text, greatest(2, length(total::text)), '0') AS ref,
           jsonb_build_object(
             'band',                     band,
             'planned_load_vs_own_norm', load_level,
             'released_deviations_7d',   dev_keys
           ) AS inputs
      FROM numbered
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('ref', ref) || inputs ORDER BY ref), '[]'::jsonb),
         COALESCE(jsonb_agg(jsonb_build_object('ref', ref, 'person_id', person_id) ORDER BY ref), '[]'::jsonb),
         COALESCE(jsonb_agg(inputs ORDER BY inputs::text), '[]'::jsonb),
         count(*)
    INTO v_cands, v_refs, v_hash_in, v_count
    FROM shaped;

  IF v_count = 0 THEN
    RETURN jsonb_build_object('call_id', NULL, 'candidates', '[]'::jsonb, 'refs', '[]'::jsonb);
  END IF;

  v_ctx := jsonb_build_object(
    'duration_min',      v_session.duration_min,
    'planned_intensity', v_session.planned_intensity,
    'session_type',      v_session.session_type
  );

  -- v_hash_in ist die kanonisch sortierte Kandidatenliste ohne ref und person_id.
  -- v_hash bleibt als informative Spalte im Protokoll erhalten (zeigt gleiche
  -- Eingaben an), traegt seit dem Nachtrag aber nicht mehr die Drosselung
  -- selbst -- die laeuft jetzt zaehlbasiert, siehe unten.
  v_hash := encode(pg_catalog.sha256(convert_to(
              jsonb_build_object('rule_version', 'v1', 'session', v_ctx, 'athletes', v_hash_in)::text,
              'UTF8')), 'hex');

  -- ---------------------------------------------------------------------------
  -- Punkt 86 (Nachtrag 2026-09-29): zaehlbasierte Drosselung pro Team UND
  -- Person statt Hash-exakt (Begruendung a/b/c im Kopfkommentar). Der
  -- advisory Lock serialisiert parallele Aufrufe derselben Person auf
  -- denselben Schluessel -- die zweite Transaktion wartet, bis die erste
  -- committed (oder zurueckrollt), und zaehlt danach die inzwischen bereits
  -- eingefuegte Zeile der ersten mit. pg_advisory_xact_lock gibt den Lock
  -- automatisch am Transaktionsende frei (COMMIT oder ROLLBACK), kein
  -- manuelles unlock noetig.
  -- ---------------------------------------------------------------------------
  PERFORM pg_advisory_xact_lock(hashtext(v_team_id::text || ':' || v_actor_id::text));

  SELECT count(*) INTO v_recent_calls
    FROM app.model_call_log l
   WHERE l.team_id      = v_team_id
     AND l.actor_kind   = 'person'
     AND l.actor_id     = v_actor_id
     AND l.purpose      = 'ap69_squad_check'
     AND l.occurred_at  > now() - c_rate_limit_window;

  IF v_recent_calls >= c_rate_limit_max_calls THEN
    RAISE EXCEPTION 'RATE_LIMITED: squad_check.jev_context' USING errcode = '55000';
  END IF;

  INSERT INTO app.model_call_log (
    team_id, purpose, actor_kind, actor_id, actor_role, context_ref,
    provider, model, rule_version, input_hash, subject_count
  )
  VALUES (
    v_team_id, 'ap69_squad_check', 'person', v_actor_id, app.denial_actor_role(), p_session_id,
    c_provider, c_model, 'v1', v_hash, v_count
  )
  RETURNING id, finish_token INTO v_call_id, v_finish_token;

  INSERT INTO app.model_call_subjects (call_id, team_id, person_id)
  SELECT v_call_id, v_team_id, (e ->> 'person_id')::uuid
    FROM jsonb_array_elements(v_refs) e;

  RETURN jsonb_build_object(
    'call_id',      v_call_id,
    'finish_token', v_finish_token,
    'provider',     c_provider,
    'model',        c_model,
    'rule_version', 'v1',
    'session',      v_ctx,
    'candidates',   v_cands,
    'refs',         v_refs
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) IS
  'AP-69: einzige Quelle der JEV-Eingaben. Muster D, nur Staff, eigenes Team (sonst P0002), '
  'Schalter jev_squad_check_enabled (sonst 55000), nur gespeicherte Einheiten. Schreibt die '
  'pending-Zeile in app.model_call_log plus model_call_subjects, BEVOR der Kontext zurueckgeht. '
  'candidates ohne person_id/Name, refs getrennt fuer die Rueckuebersetzung auf dem Server. '
  'Punkt 86 (Nachtrag 2026-09-29): RATE_LIMITED (55000) ab '
  'c_rate_limit_max_calls Aufrufen pro Team UND Person innerhalb c_rate_limit_window, '
  'serialisiert per pg_advisory_xact_lock. duration_min/planned_intensity kommen aus der '
  'gespeicherten Session, nicht mehr aus p_duration_min/p_planned_intensity (Client-Werte '
  'werden nur noch fuer die NOT_FOUND/session_id-Pruefung indirekt gebraucht, sonst ignoriert). '
  'Punkt 87 (Nachtrag 2026-09-29): p_context_secret muss gegen app.jev_context_secret passen '
  '(sonst FORBIDDEN, BEVOR irgendeine Zeile entsteht), gibt zusaetzlich finish_token zurueck, '
  'das app.rpc_finish_model_call verifiziert. Siehe backend/44_jev_rate_limit_and_finish_token.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. app.rpc_finish_model_call — zusaetzlich p_finish_token (Punkt 87).
--    Signatur aendert sich (neuer 4. Parameter) -> DROP + CREATE statt REPLACE.
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_finish_model_call(bigint, text, integer);
DROP FUNCTION IF EXISTS app.rpc_finish_model_call(bigint, text, integer);

CREATE FUNCTION app.rpc_finish_model_call(
  p_call_id       bigint,
  p_result_class  text,
  p_latency_ms    integer,
  p_finish_token  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_id bigint;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('model_call_log.finish', 'FORBIDDEN: model_call_log.finish');
  END IF;

  IF p_result_class IS NULL OR p_result_class NOT IN
     ('ok','partial','invalid','timeout','rate_limited','http_error') THEN
    RAISE EXCEPTION 'INVALID: model_call_log.result_class' USING errcode = '22023';
  END IF;

  IF p_latency_ms IS NOT NULL AND p_latency_ms < 0 THEN
    RAISE EXCEPTION 'INVALID: model_call_log.latency_ms' USING errcode = '22023';
  END IF;

  IF p_finish_token IS NULL THEN
    RETURN app.deny('model_call_log.finish', 'FORBIDDEN: model_call_log.finish');
  END IF;

  UPDATE app.model_call_log
     SET result_class = p_result_class,
         latency_ms   = p_latency_ms,
         finished_at  = now()
   WHERE id           = p_call_id
     AND team_id      = app.auth_team_id()
     AND actor_kind   = 'person'
     AND actor_id     = app.auth_person_id()
     AND result_class = 'pending'
     AND occurred_at  > now() - interval '5 minutes'
     -- Punkt 87 (2026-09-29): zusaetzlich zu Person/Team/Status/Zeitfenster
     -- muss das bei der Kontext-Tuer erzeugte, pro Aufruf zufaellige Token
     -- passen. Siehe Kopfkommentar von backend/44_jev_rate_limit_and_finish_token.sql
     -- fuer die bewusste Abgrenzung (kein Service-Role-Weg, keine
     -- vollstaendige Haertung gegen einen Direktaufrufer beider Tueren).
     AND finish_token = p_finish_token
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN app.deny('model_call_log.finish', 'FORBIDDEN: model_call_log.finish');
  END IF;

  RETURN jsonb_build_object('call_id', v_id, 'result_class', p_result_class);
END;
$$;

COMMENT ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) IS
  'AP-69: schliesst eine eigene pending-Zeile in app.model_call_log ab (eigene Person, eigenes '
  'Team, juenger als 5 Minuten, korrektes finish_token aus der Kontext-Tuer -- Punkt 87, '
  '2026-09-29). result_class ohne pending, sonst 22023. Alles andere deny. '
  'Siehe backend/41_jev_switch_model_call_log.sql, backend/44_jev_rate_limit_and_finish_token.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Tuer in public — neue Signatur
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.rpc_finish_model_call(p_call_id bigint, p_result_class text, p_latency_ms integer, p_finish_token uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_finish_model_call(p_call_id, p_result_class, p_latency_ms, p_finish_token);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) IS
  'API-Tuer fuer app.rpc_finish_model_call. Invoker, nur authenticated. AP-69, Punkt 87.';

REVOKE EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. Tuer in public fuer app.rpc_squad_check_jev_context — neue Signatur
--    (Punkt 87 Nachtrag: zusaetzlicher p_context_secret Parameter). Die alte
--    Signatur wurde bereits am Kopf von Abschnitt 2b per DROP entfernt.
-- -----------------------------------------------------------------------------

CREATE FUNCTION public.rpc_squad_check_jev_context(
  p_session_id uuid, p_duration_min smallint, p_planned_intensity smallint, p_context_secret text
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_squad_check_jev_context(p_session_id, p_duration_min, p_planned_intensity, p_context_secret);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint, text) IS
  'API-Tuer fuer app.rpc_squad_check_jev_context. Invoker, nur authenticated. AP-69, Punkt 87 Nachtrag '
  '(p_context_secret, 2026-09-29).';

REVOKE EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint, text) TO authenticated, service_role;
