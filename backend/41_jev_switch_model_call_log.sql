-- =============================================================================
-- 41_jev_switch_model_call_log.sql — AP-69 Plan gegen Zustand, Teil 2:
-- JEV-Zuordnung hinter Schalter, Aufrufprotokoll ohne Inhalt
--
-- BEWUSSTE AUSNAHME VON ADR-019 §3.6 (Anbieter), analog zur E3-Ausnahme:
--   ADR-019 §3.6 schliesst fuer Modellaufrufe mit Personenbezug Router und
--   Anbieter ohne AVV aus, auch bei pseudonymisierten Daten. AP-69 laeuft
--   trotzdem zunaechst ueber OpenRouter (Router ohne AVV mit TPOS) zu
--   TypeSafe/JEV (typesafe/jev-1.13). Chris hat diesen Widerspruch am
--   2026-09-27 im Chat ausdruecklich gesehen und bestaetigt: bewusste,
--   zusaetzliche Ausnahme, gleiche Risikolage wie E3 (DSGVO-Risiko bis ein AVV
--   steht, liegt bei Chris/dem Unternehmen). Das Ziel bleibt der direkte
--   TypeSafe-Weg mit AVV nach Art. 28, EU/EWR, Zero Data Retention; ein
--   spaeterer Wechsel aendert nur provider in app.model_call_log (Werteliste
--   kennt 'typesafe' bereits). Dokumentiert in ADR-019 §3.6 (zweiter
--   Warnkasten) und docs/legal/vvt.md §4. Fuer jeden kuenftigen Anbieter gilt
--   die Regel aus §3.6 unveraendert.
--
-- Drei Ebenen muessen gleichzeitig "an" sein, sonst geht nichts an ein Modell:
--   1. Betreiber-Notaus (Next.js, nicht hier): Env JEV_ENABLED=true UND ein
--      API-Key vorhanden. Unabhaengig vom Team-Schalter.
--   2. Team-Schalter app.module_flags 'jev_squad_check_enabled', Standard aus,
--      setzen darf ihn NUR admin (mit Chris final entschieden, nicht coach).
--   3. Enger Kandidatenfilter in app.rpc_squad_check_jev_context: nur Personen
--      mit Regel-Vorschlag "volle Gruppe" (kein Spiegel, nicht schon eskaliert)
--      und mindestens einem nicht weggeklickten Hinweis h1/h2/h4, j1 nicht
--      weggeklickt.
-- JEV kann das v1-Ergebnis nur von "volle Gruppe" auf "reduziert" heben. Die
-- Optionen individual/aussetzen existieren in der Frage an JEV gar nicht, und
-- ein Freigabe-Spiegel kommt nie in die Kandidatenmenge (ADR-019 §5.1).
--
-- Eingaben an JEV je Kandidat (ADR-019 §3.4 I1, nur coach-sichtbar):
--   ref (zufaelliges Pseudonym je Aufruf, nie person_id/Name/Trikotnummer/
--   Position), band, planned_load_vs_own_norm als Stufe (nie die rohe
--   z-Zahl), released_deviations_7d als statement_key-Liste. NIE score_total,
--   factors, Check-in-Status, Schmerzwert, Body Map, Freigabestatus. Session-
--   Kontext ohne Personenbezug: Dauer, geplante Intensitaet, Typ.
--   Die Rueckuebersetzung ref -> person_id liefert die Tuer getrennt (refs),
--   sie verlaesst den Server nie Richtung Modell (Next.js baut den Request
--   ausschliesslich aus candidates).
--
-- Aufrufprotokoll (ADR-019 §3.3 Punkt 5, §3.7): app.model_call_log haelt
-- Zeitpunkt, Zweck, Ausloeser, Anbieter, Modell, Regelversion, Hash der
-- Eingabe, Zahl der Betroffenen und Ergebnisklasse fest, app.model_call_
-- subjects die betroffenen Personen. KEINE Spalte fuer Prompt, Antwort oder
-- Payload, auch nicht als jsonb. Kein Leseweg fuer Clients in diesem Paket.
-- Die Tuer legt die Zeile (pending) an, BEVOR sie den Kontext herausgibt.
-- Laeuft der Modellaufruf danach ins Leere, bleibt die Zeile sichtbar pending.
--
-- input_hash: sha256 ueber die kanonisch sortierten Eingaben ohne ref und
-- person_id (jsonb-Textform ist schluesselsortiert, die Kandidaten werden nach
-- ihrer Textform sortiert). Berechnet mit pg_catalog.sha256 statt
-- extensions.digest: identischer Hexwert, aber Kernfunktion (seit PG 11), damit
-- die Migration nicht davon abhaengt, in welchem Schema pgcrypto liegt (Cloud:
-- extensions, lokale Test-DB: public). Bekannte Grenze: ungesalzen. Der
-- Eingaberaum (Band x Laststufe x Schluessel) ist klein, der Hash beweist also
-- Gleichheit von Eingaben, er verbirgt sie nicht. Er enthaelt keinen
-- Personenbezug. Haertung (HMAC mit Server-Geheimnis) ist ein offener Punkt
-- aus der Planung, nicht Teil dieses Pakets.
--
-- Umbau app.rpc_set_module_flag: bisher fest auf doctor verdrahtet. Jetzt
-- entscheidet app._module_flag_setters(flag) ueber die Rollen je Flag:
-- loaddeviation_enabled -> {doctor} (unveraendert), jev_squad_check_enabled
-- -> {admin}, jedes andere Flag -> {} (deny). set_by_role kommt aus
-- app.denial_actor_role(). CREATE OR REPLACE, Signatur und Rueckgabetyp
-- gleich, ACL bleibt erhalten.
--
-- app.rpc_shred_person: CREATE OR REPLACE. Rumpf 1:1 aus der zuletzt
-- gueltigen Fassung (backend/30_clearance_proposals.sql, die 14_shred_person.
-- sql um clearance_proposals ergaenzt hat -- die Fassung aus 14 allein haette
-- diese Ergaenzung stillschweigend zurueckgedreht), ergaenzt in Schritt 3b.
--
-- Muster D wie 40_squad_check.sql. Voraussetzung: 40_squad_check.sql.
-- Idempotent. Tests: backend/41_jev_switch_model_call_log.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Schalter: app._module_flag_setters und Umbau app.rpc_set_module_flag
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._module_flag_setters(p_flag text)
RETURNS app.app_role[]
LANGUAGE sql
IMMUTABLE
SET search_path = app, pg_temp
AS $$
  SELECT CASE p_flag
    -- Modul-LoadDeviation.md Abschnitt 4: ausschliesslich doctor, nicht admin.
    WHEN 'loaddeviation_enabled'   THEN ARRAY['doctor']::app.app_role[]
    -- AP-69 (mit Chris final entschieden, 2026-09-27): ausschliesslich admin.
    WHEN 'jev_squad_check_enabled' THEN ARRAY['admin']::app.app_role[]
    ELSE ARRAY[]::app.app_role[]
  END;
$$;

COMMENT ON FUNCTION app._module_flag_setters(text) IS
  'Welche Rollen ein Modul-Flag setzen duerfen. loaddeviation_enabled -> doctor, '
  'jev_squad_check_enabled -> admin, unbekanntes Flag -> leer (deny). AP-69.';

REVOKE EXECUTE ON FUNCTION app._module_flag_setters(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app.rpc_set_module_flag(p_flag text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row  app.module_flags;
  v_role app.app_role;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('module_flags.set', 'FORBIDDEN: module_flags.set');
  END IF;

  -- Bestaetigtes Team heisst: der Claim app_role ist gegen role_assignments
  -- geprueft und damit ein gueltiger Enum-Wert (08_reconciling.sql).
  v_role := app.denial_actor_role();

  IF v_role IS NULL
     OR NOT (v_role = ANY (app._module_flag_setters(p_flag)))
     OR NOT app.auth_has_role(v_role) THEN
    RETURN app.deny('module_flags.set', 'FORBIDDEN: module_flags.set');
  END IF;

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'INVALID: module_flags.enabled' USING errcode = '22023';
  END IF;

  INSERT INTO app.module_flags (team_id, flag, enabled, set_by, set_by_role, set_at)
  VALUES (app.auth_team_id(), p_flag, p_enabled, app.auth_person_id(), v_role, now())
  ON CONFLICT (team_id, flag) DO UPDATE
    SET enabled = EXCLUDED.enabled, set_by = EXCLUDED.set_by,
        set_by_role = EXCLUDED.set_by_role, set_at = EXCLUDED.set_at
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'flag', v_row.flag, 'enabled', v_row.enabled,
    'set_by', v_row.set_by, 'set_at', v_row.set_at
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_set_module_flag(text, boolean) IS
  'Modul-Flag setzen, Muster D. Rolle je Flag aus app._module_flag_setters: '
  'loaddeviation_enabled nur doctor, jev_squad_check_enabled nur admin, unbekannt deny. '
  'set_by_role aus app.denial_actor_role(). AP-69 Umbau, siehe backend/41_jev_switch_model_call_log.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_set_module_flag(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_set_module_flag(text, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. app.model_call_log / app.model_call_subjects — ohne Inhalt
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.model_call_log (
  id            bigserial PRIMARY KEY,
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  purpose       text NOT NULL CHECK (purpose IN ('ap69_squad_check')),
  actor_kind    text NOT NULL CHECK (actor_kind IN ('person','job')),
  actor_id      uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  actor_role    app.app_role,
  job_key       text,
  CHECK ((actor_kind = 'person' AND actor_id IS NOT NULL AND actor_role IS NOT NULL AND job_key IS NULL)
      OR (actor_kind = 'job' AND job_key IS NOT NULL AND actor_id IS NULL AND actor_role IS NULL)),
  context_ref   uuid,
  provider      text NOT NULL CHECK (provider IN ('openrouter','typesafe')),
  model         text NOT NULL CHECK (model NOT LIKE '%latest%'),
  rule_version  text NOT NULL,
  input_hash    text NOT NULL,
  subject_count smallint NOT NULL,
  result_class  text NOT NULL DEFAULT 'pending' CHECK (result_class IN
                ('pending','ok','partial','invalid','timeout','rate_limited','http_error')),
  latency_ms    integer
);

CREATE INDEX IF NOT EXISTS model_call_log_team_occurred_idx
  ON app.model_call_log (team_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS model_call_log_actor_idx
  ON app.model_call_log (actor_id) WHERE actor_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS app.model_call_subjects (
  call_id   bigint NOT NULL REFERENCES app.model_call_log(id) ON DELETE CASCADE,
  team_id   uuid   NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id uuid   NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  PRIMARY KEY (call_id, person_id)
);

CREATE INDEX IF NOT EXISTS model_call_subjects_person_idx
  ON app.model_call_subjects (person_id);

COMMENT ON TABLE app.model_call_log IS
  'ADR-019 §3.3/§3.7: Aufrufprotokoll fuer Modellaufrufe mit Personenbezug, OHNE Inhalt. '
  'Keine Spalte fuer Prompt, Antwort oder Payload. Kein Leseweg fuer Clients. AP-69.';
COMMENT ON TABLE app.model_call_subjects IS
  'ADR-019 §3.3: betroffene Personen je Modellaufruf. app.rpc_shred_person loescht sie. AP-69.';

ALTER TABLE app.model_call_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.model_call_log FORCE ROW LEVEL SECURITY;
ALTER TABLE app.model_call_subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.model_call_subjects FORCE ROW LEVEL SECURITY;

REVOKE ALL ON app.model_call_log, app.model_call_subjects FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE app.model_call_log_id_seq FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. app.rpc_squad_check_jev_context — die einzige Tuer, aus der JEV-Eingaben
--    entstehen
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
  c_provider   CONSTANT text := 'openrouter';
  c_model      CONSTANT text := 'typesafe/jev-1.13';
  v_team_id    uuid;
  v_session    app.training_sessions%rowtype;
  v_rows       jsonb;
  v_ctx        jsonb;
  v_cands      jsonb;
  v_refs       jsonb;
  v_hash_in    jsonb;
  v_hash       text;
  v_count      integer;
  v_call_id    bigint;
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
             'band',                     COALESCE(band, 'unknown'),
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

  INSERT INTO app.model_call_log (
    team_id, purpose, actor_kind, actor_id, actor_role, context_ref,
    provider, model, rule_version, input_hash, subject_count
  )
  VALUES (
    v_team_id, 'ap69_squad_check', 'person', app.auth_person_id(), app.denial_actor_role(), p_session_id,
    c_provider, c_model, 'v1', v_hash, v_count
  )
  RETURNING id INTO v_call_id;

  INSERT INTO app.model_call_subjects (call_id, team_id, person_id)
  SELECT v_call_id, v_team_id, (e ->> 'person_id')::uuid
    FROM jsonb_array_elements(v_refs) e;

  RETURN jsonb_build_object(
    'call_id',      v_call_id,
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
  'Siehe backend/41_jev_switch_model_call_log.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. app.rpc_finish_model_call — nur die eigene, frische pending-Zeile
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_finish_model_call(
  p_call_id       bigint,
  p_result_class  text,
  p_latency_ms    integer
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
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN app.deny('model_call_log.finish', 'FORBIDDEN: model_call_log.finish');
  END IF;

  RETURN jsonb_build_object('call_id', v_id, 'result_class', p_result_class);
END;
$$;

COMMENT ON FUNCTION app.rpc_finish_model_call(bigint, text, integer) IS
  'AP-69: schliesst eine eigene pending-Zeile in app.model_call_log ab (eigene Person, eigenes '
  'Team, juenger als 5 Minuten). result_class ohne pending, sonst 22023. Alles andere deny. '
  'Siehe backend/41_jev_switch_model_call_log.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_squad_check_jev_context(
  p_session_id uuid, p_duration_min smallint, p_planned_intensity smallint
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_squad_check_jev_context(p_session_id, p_duration_min, p_planned_intensity);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_finish_model_call(p_call_id bigint, p_result_class text, p_latency_ms integer)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_finish_model_call(p_call_id, p_result_class, p_latency_ms);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint) IS 'API-Tuer fuer app.rpc_squad_check_jev_context. Invoker, nur authenticated. AP-69.';
COMMENT ON FUNCTION public.rpc_finish_model_call(bigint, text, integer) IS 'API-Tuer fuer app.rpc_finish_model_call. Invoker, nur authenticated. AP-69.';

REVOKE EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_shred_person — Loeschpfad um Aufrufprotokoll und Wegklicks
--    erweitert (ADR-019 T6)
-- -----------------------------------------------------------------------------
-- Rumpf Zeile fuer Zeile aus backend/30_clearance_proposals.sql, neu ist nur
-- Schritt 3b. CREATE OR REPLACE (nicht DROP+CREATE): Signatur und Rueckgabetyp
-- bleiben, die ACL (kein EXECUTE fuer authenticated, Punkt 55) bleibt erhalten.
-- Das REVOKE unten steht trotzdem, als Schutz fuer einen Neuaufbau.
--
-- Schritt 3b:
--   * model_call_subjects: die Zeile nennt die Person als Betroffene eines
--     Modellaufrufs, sie geht.
--   * model_call_log: die Person als AUSLOESERIN. Die Zeile bleibt als
--     Nachweis, dass es den Aufruf gab (Art. 5 Abs. 2), der Ausloeser wird
--     anonymisiert (actor_kind job, job_key shredded). Anders als access_log.
--     actor_id (bleibt stehen, siehe Schritt 4), weil ein Modellaufruf kein
--     Nachweis ueber Zugriffe auf die Daten einer DRITTEN Person ist, den diese
--     Dritte einsehen koennen muss -- die Betroffenen stehen in den Subjects.
--   * session_hint_dismissals: Wegklicks FUER die Person gehen (sie sagen
--     etwas ueber ihren Zustand an einem Tag). Wegklicks DURCH die Person
--     bleiben als Teamstand der Einheit stehen, dismissed_by wird NULL. Der FK
--     ON DELETE SET NULL greift hier nicht, weil die Personenzeile nie
--     geloescht, nur anonymisiert wird (Schritt 5).
--   Keine der drei Tabellen traegt den Audit Trigger, Schritt 6 muss fuer sie
--   nichts nachraeumen.

CREATE OR REPLACE FUNCTION app.rpc_shred_person(p_person_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_team_id       uuid;
  v_actor_id      uuid;
  v_auth_user_id  uuid;
  v_found         boolean;
  v_now           timestamptz := now();
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1. Berechtigung. Nur admin, nur das eigene Team.
  -- ---------------------------------------------------------------------------
  IF NOT app.auth_has_role('admin') THEN
    PERFORM app.log_denial('persons.shred');
    RAISE EXCEPTION 'FORBIDDEN: persons.shred (only admin)' USING errcode = '42501';
  END IF;

  v_team_id  := app.auth_team_id();
  v_actor_id := app.auth_person_id();

  -- Die Person muss es im eigenen Team geben. v1 lief bei einer fremden oder
  -- unbekannten id still durch und meldete Erfolg.
  SELECT p.auth_user_id, true
    INTO v_auth_user_id, v_found
    FROM app.persons p
   WHERE p.id = p_person_id
     AND p.team_id = v_team_id;

  IF NOT coalesce(v_found, false) THEN
    RAISE EXCEPTION 'NOT_FOUND: persons.shred' USING errcode = 'P0002';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. Nutzdaten. Fuer Trainingsbefinden besteht keine Aufbewahrungspflicht.
  --    Jedes DELETE hier erzeugt ueber app.audit_log_trigger() eine Audit Zeile
  --    mit vollstaendiger Kopie. Schritt 6 raeumt sie im selben Aufruf mit ab.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.daily_checkins    WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.readiness_scores  WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.load_deviations   WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 3. Medizinische Freigaben (Entscheidung 1: loeschen).
  --    Vorbehalt der anwaltlichen Gegenprobe zu § 630f BGB: zaehlt die Freigabe
  --    des Mannschaftsarztes als aerztliche Dokumentation, sticht Art. 17 Abs. 3
  --    lit. b das Loeschrecht, und aus diesem DELETE wird eine Reduktion.
  -- ---------------------------------------------------------------------------
  -- AP-47a: die Vorschlaege der Physio zuerst, sie verweisen auf dieselbe Person.
  DELETE FROM app.clearance_proposals WHERE person_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.medical_clearances  WHERE person_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 3b. AP-69 (ADR-019 T6): Aufrufprotokoll der Modellaufrufe und Wegklicks.
  --     Begruendung im Kommentar ueber dieser Funktion.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.model_call_subjects WHERE person_id = p_person_id AND team_id = v_team_id;
  UPDATE app.model_call_log
     SET actor_id = NULL, actor_kind = 'job', job_key = 'shredded', actor_role = NULL
   WHERE actor_id = p_person_id AND team_id = v_team_id;
  DELETE FROM app.session_hint_dismissals WHERE person_id = p_person_id AND team_id = v_team_id;
  UPDATE app.session_hint_dismissals
     SET dismissed_by = NULL
   WHERE dismissed_by = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 4. Zugriffsprotokoll (Entscheidung 2). Jede Zeile nennt zwei Personen.
  --    Betroffene (subject_id): die Zeile gehoert dieser Person, sie geht.
  --    Handelnde (actor_id): die Zeile gehoert der betroffenen Person und ist ihr
  --    Nachweis darueber, wer in ihre Daten gesehen hat. Sie bleibt unveraendert,
  --    der Personenbezug ist ueber die anonymisierte persons Zeile aufgehoben.
  --    app.access_denials nennt nur Handelnde und bleibt deshalb ganz unberuehrt.
  -- ---------------------------------------------------------------------------
  DELETE FROM app.access_log WHERE subject_id = p_person_id AND team_id = v_team_id;

  -- ---------------------------------------------------------------------------
  -- 5. Personenzeile anonymisieren. Crypto Shredding: die id bleibt, damit jeder
  --    Verweis auf die Person als Handelnde weiter traegt.
  --    Die Bedingung am Ende macht den zweiten Aufruf wirkungslos statt
  --    wirkungsgleich: ohne sie schriebe jeder weitere Shred eine neue Audit
  --    Zeile und vergaebe einen neuen Pseudonymnamen.
  -- ---------------------------------------------------------------------------
  UPDATE app.persons
     SET display_name    = 'SCRAPED-' || substr(md5(random()::text), 1, 8),
         auth_user_id    = NULL,
         birth_date      = NULL,
         is_active       = false,
         -- AP-43: die Darstellungspraeferenz der Body Map faellt auf die Vorgabe
         -- zurueck. Sie ist kein Geschlechtsfeld, aber an einer namenlosen Zeile
         -- ist sie eine Restangabe ueber einen Menschen ohne jeden Zweck.
         body_map_figure = 'aus_dem_team',
         updated_at      = v_now
   WHERE id = p_person_id
     AND team_id = v_team_id
     AND (auth_user_id IS NOT NULL
          OR birth_date IS NOT NULL
          OR is_active
          OR body_map_figure <> 'aus_dem_team'
          OR display_name NOT LIKE 'SCRAPED-%');

  -- ---------------------------------------------------------------------------
  -- 6. audit_log. Laeuft ZULETZT, und das ist der Grundsatz des ganzen Pfads:
  --    app.audit_log_trigger() kopiert mit to_jsonb(OLD) und to_jsonb(NEW) ganze
  --    Zeilen. Die Schritte 2 bis 5 haben also gerade neue Kopien erzeugt. Weil
  --    diese Kopien denselben Personenbezug tragen, erfasst der Schritt sie mit.
  --    Liefe er frueher, raeumte der Pfad auf und fuellte danach nach.
  --
  --    Geleert wird der Inhalt, nicht die Zeile: table_name, row_id, operation,
  --    actor_id, actor_role und occurred_at bleiben stehen. Damit bleibt
  --    belegbar, DASS es eine Aenderung gab (Art. 5 Abs. 2, Art. 32), ohne den
  --    Inhalt zu behalten. Nebeneffekt, der gewollt ist: ein Shred taugt damit
  --    nicht zum Verwischen von Spuren.
  --
  --    Zwei Referenzformen, und nur diese zwei:
  --      a) person_id im jsonb  (daily_checkins, readiness_scores,
  --         medical_clearances, load_deviations)
  --      b) id im jsonb bei table_name = 'persons'  (dort stehen display_name
  --         und birth_date im Klartext)
  --    Verweise auf Handelnde (actor_id, set_by, proposed_by, reviewed_by)
  --    bleiben ausdruecklich unberuehrt, siehe Kopf der Datei.
  --
  --    app.audit_log traegt selbst keinen Trigger, dieses UPDATE erzeugt also
  --    keine neue Zeile.
  -- ---------------------------------------------------------------------------
  UPDATE app.audit_log a
     SET old_row = CASE WHEN a.old_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END,
         new_row = CASE WHEN a.new_row IS NULL THEN NULL
                        ELSE jsonb_build_object('shredded_at', v_now) END
   WHERE a.team_id = v_team_id
     AND (a.old_row IS NOT NULL OR a.new_row IS NOT NULL)
     AND (
           a.old_row ->> 'person_id' = p_person_id::text
        OR a.new_row ->> 'person_id' = p_person_id::text
        OR (a.table_name = 'persons'
            AND (a.old_row ->> 'id' = p_person_id::text
                 OR a.new_row ->> 'id' = p_person_id::text))
         );

  -- ---------------------------------------------------------------------------
  -- 7. Abschlusszeile. Traegt keinen Inhalt: die Person steht in row_id, nicht
  --    im jsonb. Stuende sie im jsonb, loeschte ein zweiter Shred die
  --    Abschlusszeile des ersten wieder leer.
  -- ---------------------------------------------------------------------------
  INSERT INTO app.audit_log (team_id, table_name, row_id, operation, actor_id, actor_role, old_row, new_row)
  VALUES (
    v_team_id, 'persons', p_person_id, 'DELETE',
    v_actor_id, 'admin'::app.app_role,
    NULL, jsonb_build_object('action', 'crypto_shred', 'shredded_at', v_now)
  );

  -- ---------------------------------------------------------------------------
  -- 8. Das Auth Konto liegt im Schema auth und wird ueber die Admin API geloescht,
  --    nicht per SQL. Ohne diesen zweiten Schritt bliebe die E-Mail Adresse
  --    gespeichert und machte das Pseudonym wieder aufloesbar.
  --    NULL heisst: kein Konto zu loeschen (nie eines gehabt, oder schon geshreddet).
  -- ---------------------------------------------------------------------------
  RETURN v_auth_user_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM PUBLIC, anon;
-- KEIN GRANT fuer authenticated (Punkt 55, siehe 30_clearance_proposals.sql).
REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM authenticated;

COMMENT ON FUNCTION app.rpc_shred_person(uuid) IS
  'Art. 17 DSGVO. Loescht alle Spuren einer Person in app.*, anonymisiert die '
  'Personenzeile und leert den Inhalt der zugehoerigen audit_log Zeilen, ohne '
  'deren Metadaten aufzugeben. Gibt die alte auth_user_id zurueck, damit das '
  'Auth Konto im zweiten Schritt ueber die Admin API geloescht werden kann '
  '(scripts/shred-auth-user.mjs). AP-39b. '
  'AP-47a (2026-09-22): app.clearance_proposals kommt in Schritt 3 dazu. '
  'AP-69 (2026-09-27): Schritt 3b, model_call_subjects geloescht, model_call_log-Ausloeser '
  'anonymisiert, session_hint_dismissals fuer die Person geloescht, dismissed_by NULL.';
