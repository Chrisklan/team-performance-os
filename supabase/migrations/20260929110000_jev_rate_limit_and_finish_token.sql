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
-- verifiziert. Offene Grenze, ehrlich benannt: wer die Kontext-Tuer DIREKT
-- aufruft (statt ueber die App), erhaelt call_id UND finish_token in
-- DERSELBEN Antwort und koennte damit weiterhin selbst abschliessen -- das
-- Token schuetzt nicht gegen einen Angreifer, der den kompletten Aufrufpfad
-- selbst nachbaut, sondern schliesst den einfacheren Fall, dass eine
-- Finish-Zeile ohne JEDE Kenntnis eines Aufrufgeheimnisses abgeschlossen
-- werden kann (z.B. Erraten/Beobachten einer eigenen frueheren call_id ohne
-- zugehoerigen Kontext-Aufruf). Vollstaendige Haertung braucht einen
-- Server-Weg ohne Nutzer-JWT (Service Role oder eigener API-Endpunkt mit
-- Secret) -- das ist der Zielzustand, den ADR-019 §3.6 fuer den spaeteren
-- TypeSafe-Direktweg ohnehin vorsieht, hier bewusst nicht vorgezogen.
--
-- app.rpc_squad_check_jev_context/app.rpc_finish_model_call Rumpf 1:1 aus
-- backend/41_jev_switch_model_call_log.sql, CREATE OR REPLACE bzw. (wegen
-- geaenderter Signatur bei rpc_finish_model_call) DROP + CREATE.
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
-- 2. app.rpc_squad_check_jev_context — Drosselung (Punkt 86) + finish_token
--    in der Rueckgabe (Punkt 87)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_squad_check_jev_context(
  p_session_id         uuid,
  p_duration_min       smallint,
  p_planned_intensity  smallint
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
  c_provider     CONSTANT text := 'openrouter';
  c_model        CONSTANT text := 'typesafe/jev-1.13';
  v_team_id      uuid;
  v_session      app.training_sessions%rowtype;
  v_rows         jsonb;
  v_ctx          jsonb;
  v_cands        jsonb;
  v_refs         jsonb;
  v_hash_in      jsonb;
  v_hash         text;
  v_count        integer;
  v_call_id      bigint;
  v_finish_token uuid;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  v_team_id := app.auth_team_id();

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

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: squad_check.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NULL OR p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: squad_check.planned_intensity' USING errcode = '22023';
  END IF;

  v_rows := app._squad_check_v1(v_team_id, v_session.session_date, p_duration_min, p_planned_intensity, p_session_id);

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
    'duration_min',      p_duration_min,
    'planned_intensity', p_planned_intensity,
    'session_type',      v_session.session_type
  );

  -- v_hash_in ist die kanonisch sortierte Kandidatenliste ohne ref und person_id.
  v_hash := encode(pg_catalog.sha256(convert_to(
              jsonb_build_object('rule_version', 'v1', 'session', v_ctx, 'athletes', v_hash_in)::text,
              'UTF8')), 'hex');

  -- ---------------------------------------------------------------------------
  -- Punkt 86 (2026-09-29): Drosselung. Derselbe input_hash im selben Team
  -- innerhalb der letzten 5 Minuten (dasselbe Fenster wie rpc_finish_model_
  -- call) -> kein neuer bezahlter Aufruf. squadCheckActions.ts faengt JEDEN
  -- Fehler dieser Tuer ab und faellt auf Regel v1 zurueck, RATE_LIMITED
  -- braucht also keinen eigenen Frontend-Zweig.
  -- ---------------------------------------------------------------------------
  IF EXISTS (
    SELECT 1 FROM app.model_call_log l
     WHERE l.team_id = v_team_id
       AND l.purpose = 'ap69_squad_check'
       AND l.input_hash = v_hash
       AND l.occurred_at > now() - interval '5 minutes'
  ) THEN
    RAISE EXCEPTION 'RATE_LIMITED: squad_check.jev_context' USING errcode = '55000';
  END IF;

  INSERT INTO app.model_call_log (
    team_id, purpose, actor_kind, actor_id, actor_role, context_ref,
    provider, model, rule_version, input_hash, subject_count
  )
  VALUES (
    v_team_id, 'ap69_squad_check', 'person', app.auth_person_id(), app.denial_actor_role(), p_session_id,
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

COMMENT ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint) IS
  'AP-69: einzige Quelle der JEV-Eingaben. Muster D, nur Staff, eigenes Team (sonst P0002), '
  'Schalter jev_squad_check_enabled (sonst 55000), nur gespeicherte Einheiten. Schreibt die '
  'pending-Zeile in app.model_call_log plus model_call_subjects, BEVOR der Kontext zurueckgeht. '
  'candidates ohne person_id/Name, refs getrennt fuer die Rueckuebersetzung auf dem Server. '
  'Punkt 86 (2026-09-29): RATE_LIMITED (55000), wenn derselbe input_hash im selben Team '
  'innerhalb 5 Minuten schon lief. Punkt 87: gibt finish_token zurueck, das '
  'app.rpc_finish_model_call verifiziert. Siehe backend/44_jev_rate_limit_and_finish_token.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint) TO authenticated;

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
