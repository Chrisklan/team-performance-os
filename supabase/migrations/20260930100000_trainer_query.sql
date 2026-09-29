-- =============================================================================
-- 48_trainer_query.sql — AP-70b: Trainer-Query-Funktion, Tuer-Oeffner
--
-- Baut NUR die Tuer (app.rpc_trainer_query_open), die auf dem Gateway-Kern aus
-- backend/47_model_gateway_core.sql aufsetzt -- keine eigene Secret-/
-- Drosselungs-Logik. Die Tuer legt die pending-Zeile in app.model_call_log an
-- und gibt AUSSCHLIESSLICH {call_id, finish_token, provider, model,
-- rule_version} zurueck, KEINE Kaderdaten (die liest der Server danach separat
-- ueber public.rpc_trainer_morning_ops mit demselben JWT).
--
-- 1. app._mg_purpose_config: um Zweig 'ap70_trainer_query' erweitert
--    (provider openrouter, Modell typesafe/jev-1.13 -- dasselbe gepinnte
--    JEV-Modell wie AP-69, rule_version v1, Schalter trainer_query_enabled,
--    10 Aufrufe/5 Minuten je Person, allowed_roles coach/athletic_coach,
--    allow_empty_subjects true -- eine Zaehl-/Listenfrage ohne player_ref-
--    Filter hat keine Subjekte).
-- 2. app._module_flag_setters: um 'trainer_query_enabled' -> {admin} erweitert
--    (gleiches Muster wie jev_squad_check_enabled, 41).
-- 3. app._mg_daily_cap(purpose, deny_key, daily_max) — zusaetzliche
--    Deckelungsebene UEBER app._mg_throttle hinaus: Tagesobergrenze je Team
--    (nicht je Person), 200/Tag fuer ap70_trainer_query. Gleiches
--    pg_advisory_xact_lock-Muster wie app._mg_throttle (47) bzw. Punkt 86 (44).
-- 4. app.rpc_trainer_query_open(p_input_hash, p_subject_ids, p_context_secret)
--    — Pruefreihenfolge: Team -> Staff (nur coach/athletic_coach) ->
--    _mg_secret_ok -> Schalter trainer_query_enabled -> _mg_throttle ->
--    _mg_daily_cap -> _mg_open. Rueckgabe NUR call_id/finish_token/provider/
--    model/rule_version.
--
-- Voraussetzung: 47_model_gateway_core.sql. Idempotent (CREATE OR REPLACE).
-- Tests: backend/48_trainer_query.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app._mg_purpose_config — Zweig 'ap70_trainer_query' ergaenzt.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._mg_purpose_config(p_purpose text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = app, pg_temp
AS $$
  SELECT CASE p_purpose
    WHEN 'ap69_squad_check' THEN jsonb_build_object(
      'provider',      'openrouter',
      'model',         'typesafe/jev-1.13',
      'rule_version',  'v1',
      'flag',          'jev_squad_check_enabled',
      'rate_max',      5,
      'rate_window',   '5 minutes',
      'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
      'allow_empty_subjects', true
    )
    WHEN 'ap70_trainer_query' THEN jsonb_build_object(
      -- Dasselbe gepinnte JEV-Modell wie AP-69 (geschlossene Choice-Fragen,
      -- kein Freitext). ADR-019 §3.2: nie -latest.
      'provider',      'openrouter',
      'model',         'typesafe/jev-1.13',
      'rule_version',  'v1',
      'flag',          'trainer_query_enabled',
      'rate_max',      10,
      'rate_window',   '5 minutes',
      'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
      -- Eine Zaehl-/Listenfrage ohne player_ref-Filter ("keine") hat keine
      -- Subjekte -- leeres Array muss durch app._mg_open kommen.
      'allow_empty_subjects', true
    )
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION app._mg_purpose_config(text) IS
  'AP-70a/AP-70b: feste Konfiguration je Modell-Zweck (Muster wie app._module_flag_setters, 41). '
  'ap69_squad_check haelt die AP-69-Werte, ap70_trainer_query die Trainer-Query-Werte '
  '(Schalter trainer_query_enabled, 10 Aufrufe/5min je Person, coach/athletic_coach). '
  'Unbekannter Zweck -> NULL. Siehe backend/47_model_gateway_core.sql, backend/48_trainer_query.sql.';

-- REVOKE bereits in 47 gesetzt (Funktion unveraendert in ihren Rechten, nur der Rumpf waechst).

-- -----------------------------------------------------------------------------
-- 1b. app.model_call_log.purpose — CHECK-Erweiterung um 'ap70_trainer_query'.
--     Constraint-Name idempotent ueber pg_constraint gesucht (nicht hart
--     kodiert), gleiches Muster wie der result_class-Constraint in 47.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT c.conname INTO v_constraint_name
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname = 'app'
     AND t.relname = 'model_call_log'
     AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) LIKE '%purpose%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE app.model_call_log DROP CONSTRAINT %I', v_constraint_name);
  END IF;

  ALTER TABLE app.model_call_log ADD CONSTRAINT model_call_log_purpose_check
    CHECK (purpose IN ('ap69_squad_check', 'ap70_trainer_query'));
END;
$$;

COMMENT ON CONSTRAINT model_call_log_purpose_check ON app.model_call_log IS
  'AP-70b: purpose-Werteliste, erweitert um ap70_trainer_query. Constraint-Name bewusst fest '
  'vergeben, das vorherige (Migrations-generierte) Constraint wird zuvor idempotent ueber '
  'pg_constraint gesucht und gedroppt.';

-- -----------------------------------------------------------------------------
-- 2. app._module_flag_setters — 'trainer_query_enabled' -> {admin} ergaenzt.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._module_flag_setters(p_flag text)
RETURNS app.app_role[]
LANGUAGE sql
IMMUTABLE
SET search_path = app, pg_temp
AS $$
  SELECT CASE p_flag
    WHEN 'loaddeviation_enabled'   THEN ARRAY['doctor']::app.app_role[]
    WHEN 'jev_squad_check_enabled' THEN ARRAY['admin']::app.app_role[]
    -- AP-70b: nur admin darf die Trainer-Query-Funktion ein-/ausschalten,
    -- gleiches Muster wie jev_squad_check_enabled.
    WHEN 'trainer_query_enabled'   THEN ARRAY['admin']::app.app_role[]
    ELSE ARRAY[]::app.app_role[]
  END;
$$;

COMMENT ON FUNCTION app._module_flag_setters(text) IS
  'Welche Rollen ein Modul-Flag setzen duerfen. loaddeviation_enabled -> doctor, '
  'jev_squad_check_enabled/trainer_query_enabled -> admin, unbekanntes Flag -> leer (deny). '
  'AP-69/AP-70b.';

-- REVOKE bereits in 41 gesetzt.

-- -----------------------------------------------------------------------------
-- 3. app._mg_daily_cap — Tagesdeckel je Team UND Zweck, zusaetzlich zu
--    app._mg_throttle (die je Person UND Zweck drosselt).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._mg_daily_cap(p_purpose text, p_deny_key text, p_daily_max integer)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid := app.auth_team_id();
  v_count   integer;
BEGIN
  IF v_team_id IS NULL OR p_daily_max IS NULL OR p_daily_max < 0 THEN
    RAISE EXCEPTION 'RATE_LIMITED: %', p_deny_key USING ERRCODE = '55000';
  END IF;

  -- Eigener Schluessel (Praefix 'mg_daily'), damit derselbe Team/Zweck-Hash
  -- nicht mit dem Person/Zweck-Lock aus app._mg_throttle kollidiert.
  PERFORM pg_advisory_xact_lock(hashtext('mg_daily:' || p_purpose || ':' || v_team_id::text));

  SELECT count(*) INTO v_count
    FROM app.model_call_log l
   WHERE l.team_id    = v_team_id
     AND l.purpose     = p_purpose
     AND l.occurred_at >= date_trunc('day', now());

  IF v_count >= p_daily_max THEN
    RAISE EXCEPTION 'RATE_LIMITED: %', p_deny_key USING ERRCODE = '55000';
  END IF;
END;
$$;

COMMENT ON FUNCTION app._mg_daily_cap(text, text, integer) IS
  'AP-70b: zusaetzliche Deckelungsebene UEBER app._mg_throttle hinaus -- Tagesobergrenze je TEAM '
  '(nicht je Person) und Zweck, heutiger Kalendertag (date_trunc(''day'', now())). '
  'RATE_LIMITED (55000) bei Ueberschreitung. Serialisiert per pg_advisory_xact_lock auf einen '
  'eigenen Schluessel-Namensraum (Praefix mg_daily), damit er nicht mit app._mg_throttle kollidiert. '
  'Siehe backend/48_trainer_query.sql.';

REVOKE EXECUTE ON FUNCTION app._mg_daily_cap(text, text, integer) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. app.rpc_trainer_query_open — die Tuer. Liefert NUR call_id/finish_token/
--    provider/model/rule_version, KEINE Kaderdaten.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_trainer_query_open(
  p_input_hash      text,
  p_subject_ids     uuid[],
  p_context_secret  text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  c_purpose CONSTANT text := 'ap70_trainer_query';
  c_daily_max CONSTANT integer := 200;
  v_config  jsonb;
  v_open    jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('trainer_query.open', 'FORBIDDEN: trainer_query.open');
  END IF;

  -- Nur coach/athletic_coach (app.auth_is_staff()), unabhaengig von der
  -- allowed_roles-Pruefung in app._mg_open (Verteidigung in der Tiefe, gleiches
  -- Muster wie app.rpc_squad_check_jev_context, 47).
  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('trainer_query.open', 'FORBIDDEN: trainer_query.open');
  END IF;

  -- Ohne korrektes Server-Secret keine Zeile (schliesst den Phantom-Zeilen-Weg,
  -- direkter Aufruf ohne Next.js). Bewusst VOR jedem weiteren Zugriff.
  IF NOT app._mg_secret_ok(p_context_secret) THEN
    RETURN app.deny('trainer_query.open', 'FORBIDDEN: trainer_query.open');
  END IF;

  v_config := app._mg_purpose_config(c_purpose);

  IF NOT app.module_enabled(v_config ->> 'flag') THEN
    RETURN app.deny('trainer_query.open', 'FORBIDDEN: trainer_query.open');
  END IF;

  PERFORM app._mg_throttle(c_purpose, 'trainer_query.open');
  PERFORM app._mg_daily_cap(c_purpose, 'trainer_query.open.daily', c_daily_max);

  v_open := app._mg_open(c_purpose, NULL, p_input_hash, p_subject_ids, p_context_secret);

  -- NUR die fuenf Schluessel, absichtlich KEINE Kaderdaten in der Tuer-Antwort
  -- (die liest der Server separat ueber public.rpc_trainer_morning_ops).
  RETURN jsonb_build_object(
    'call_id',      v_open -> 'call_id',
    'finish_token', v_open ->> 'finish_token',
    'provider',     v_open ->> 'provider',
    'model',        v_open ->> 'model',
    'rule_version', v_open ->> 'rule_version'
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_trainer_query_open(text, uuid[], text) IS
  'AP-70b: Tuer-Oeffner fuer die Trainer-Query-Funktion. Pruefreihenfolge: Team -> Staff '
  '(nur coach/athletic_coach) -> Secret -> Schalter trainer_query_enabled -> app._mg_throttle '
  '(10/5min je Person) -> app._mg_daily_cap (200/Tag je Team) -> app._mg_open (Rollen-/Team-Pruefung '
  'der subject_ids, legt die pending-Zeile an). Rueckgabe AUSSCHLIESSLICH call_id/finish_token/ '
  'provider/model/rule_version -- KEINE Kaderdaten. Siehe backend/48_trainer_query.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_trainer_query_open(text, uuid[], text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_trainer_query_open(text, uuid[], text) TO authenticated;

-- public-Tuer, Muster D wie app.rpc_squad_check_jev_context.
CREATE OR REPLACE FUNCTION public.rpc_trainer_query_open(
  p_input_hash text, p_subject_ids uuid[], p_context_secret text
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_trainer_query_open(p_input_hash, p_subject_ids, p_context_secret);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_trainer_query_open(text, uuid[], text) IS
  'API-Tuer fuer app.rpc_trainer_query_open. Invoker, nur authenticated. AP-70b.';

REVOKE EXECUTE ON FUNCTION public.rpc_trainer_query_open(text, uuid[], text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_trainer_query_open(text, uuid[], text) TO authenticated, service_role;
