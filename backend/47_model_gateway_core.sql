-- =============================================================================
-- 47_model_gateway_core.sql — AP-70a: gemeinsamer KI-Gateway-Kern
--
-- Baut NUR den Kern (Konfiguration, Secret, Drosselung, Tuer-Oeffner,
-- Abschluss), auf den AP-69 (JEV-Squad-Check) umgezogen wird. Die eigentliche
-- Trainer-Query-Funktion (AP-70b) kommt in einem separaten Paket -- dieses
-- Paket fuegt fuer sie keine Zeile Verhalten hinzu, nur die Konfigurations-
-- Weiche dafuer bleibt in app._mg_purpose_config() fuer einen unbekannten
-- Zweck bewusst NULL.
--
-- Ziel: app.rpc_squad_check_jev_context/app.rpc_finish_model_call bekommen
-- exakt dieselbe oeffentliche Signatur und dasselbe beobachtbare Verhalten wie
-- in backend/44_jev_rate_limit_and_finish_token.sql, delegieren ihren Rumpf
-- aber an gemeinsame Helfer, die ein spaeterer zweiter Zweck (AP-70b)
-- mitbenutzen kann, ohne app.rpc_squad_check_jev_context anzufassen.
--
-- 1. app._mg_purpose_config(purpose) — feste Konfiguration je Zweck
--    (provider/model/rule_version/flag/rate_max/rate_window/allowed_roles),
--    IMMUTABLE, CASE-basiert wie app._module_flag_setters (41). Unbekannter
--    Zweck -> NULL.
-- 2. app.model_gateway_secret — Nachfolger von app.jev_context_secret (44),
--    Singleton-Tabelle, nur Hash. app.rpc_set_jev_context_secret/
--    app._jev_context_secret_ok bleiben mit identischer Signatur bestehen,
--    delegieren aber an die neuen Gateway-Funktionen (Kompatibilitaet fuer
--    scripts/ und Doku, die den alten Namen kennen).
-- 3. app._mg_throttle(purpose, deny_key) — zaehlbasierte Drosselung wie
--    Punkt 86 (44), aber Obergrenze/Fenster aus der Konfiguration und je
--    Zweck UND Team/Person isoliert (ein ausgeschoepfter Zweck blockiert
--    einen anderen Zweck fuer dieselbe Person nicht).
-- 4. app._mg_open(purpose, context_ref, input_hash, subject_ids,
--    context_secret) — prueft Rolle gegen allowed_roles und dass jede
--    subject_id eine Person im eigenen Team ist, legt die pending-Zeile an,
--    gibt call_id/finish_token/provider/model/rule_version zurueck. F3/F4
--    (Security-Review, Fixrunde) haben die Signatur um p_context_secret
--    erweitert -- DROP FUNCTION IF EXISTS vor dem neuen CREATE, das ist die
--    EINZIGE Ausnahme von "keine Signaturaenderung" in diesem Paket.
-- 5. app.rpc_finish_model_call — CREATE OR REPLACE, Signatur unveraendert.
--    Einzige inhaltliche Aenderung: 'rejected' ist jetzt ein gueltiger
--    result_class (Ausgangswaechter hat verworfen, AP-70b). Der CHECK-
--    Constraint wird ueber pg_constraint gesucht (nicht hart kodiert), damit
--    die Migration erneut laufen kann.
-- 6. app.rpc_squad_check_jev_context — CREATE OR REPLACE, Signatur
--    unveraendert (uuid,smallint,smallint,text). Rumpf delegiert an die
--    _mg_*-Helfer, Pruefreihenfolge bleibt exakt: Team -> Staff -> Secret ->
--    Session -> Schalter -> Kandidaten -> Hash -> _mg_throttle -> _mg_open.
--    Provider/Modell kommen aus app._mg_purpose_config('ap69_squad_check')
--    statt hart codiert, mit identischen Werten.
--
-- Voraussetzung: 40_squad_check.sql, 41_jev_switch_model_call_log.sql,
-- 44_jev_rate_limit_and_finish_token.sql. Idempotent (CREATE OR REPLACE
-- ueberall; EINZIGE Ausnahme app._mg_open, dessen Signatur sich um
-- p_context_secret erweitert hat -- dort steht ein DROP FUNCTION IF EXISTS
-- vor dem CREATE, siehe Punkt 4).
-- Tests: backend/47_model_gateway_core.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app._mg_purpose_config — feste Konfiguration je Zweck
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
      -- Festgeschrieben (ADR-019 §3.2 Reproduzierbarkeit): nie -latest.
      'model',         'typesafe/jev-1.13',
      'rule_version',  'v1',
      'flag',          'jev_squad_check_enabled',
      'rate_max',      5,
      'rate_window',   '5 minutes',
      'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
      -- F3 (Security-Review, Fixrunde): leeres subject_ids-Array darf app._mg_open
      -- nur bestehen, wenn der jeweilige Zweck das hier AUSDRUECKLICH erlaubt,
      -- nicht mehr durch Zufall (leeres Array bestand die alte length-Pruefung
      -- trivial). Fuer ap69_squad_check bleibt das bisherige Verhalten erhalten
      -- (der Aufrufer gibt bei 0 Kandidaten ohnehin vorher zurueck, siehe
      -- app.rpc_squad_check_jev_context).
      'allow_empty_subjects', true
    )
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION app._mg_purpose_config(text) IS
  'AP-70a: feste Konfiguration je Modell-Zweck (Muster wie app._module_flag_setters, 41). '
  'ap69_squad_check haelt exakt die bisher hart codierten AP-69-Werte. Unbekannter Zweck -> NULL. '
  'Einzige Quelle erlaubter provider/model/rule_version/flag/rate_max/rate_window/allowed_roles '
  'je Zweck. Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app._mg_purpose_config(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2a. app.model_gateway_secret — Nachfolger von app.jev_context_secret (44).
--     Singleton (genau eine Zeile, id=true), haelt nur den sha256-Hash.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.model_gateway_secret (
  id          boolean PRIMARY KEY DEFAULT true CHECK (id),
  secret_hash text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE app.model_gateway_secret IS
  'AP-70a: Nachfolger von app.jev_context_secret (44). sha256-Hash des Server-Secrets aus der '
  'Next.js Server-Umgebung (heute JEV_CONTEXT_SECRET, kompatibel gelesen). Singleton (genau '
  'eine Zeile, id=true). Kein Leseweg fuer irgendeine Postgres-Rolle ausser dem Function-Owner '
  '(SECURITY DEFINER). Gesetzt ueber app.rpc_set_model_gateway_secret (nur service_role).';

REVOKE ALL ON app.model_gateway_secret FROM PUBLIC, anon, authenticated;

-- Uebernimmt eine evtl. vorhandene Zeile aus der alten Tabelle 1:1 (gleicher
-- Hash-Algorithmus, sha256 ueber denselben Klartext -- ein Umstellen des
-- Secrets ist dafuer nicht noetig). Auf einer frischen DB (lokale Tests,
-- Projektstand laut Auftrag: in der Cloud bislang keine Zeile gesetzt) ist
-- app.jev_context_secret leer, das INSERT betrifft dann 0 Zeilen.
DO $$
BEGIN
  IF to_regclass('app.jev_context_secret') IS NOT NULL THEN
    INSERT INTO app.model_gateway_secret (id, secret_hash, updated_at)
    SELECT s.id, s.secret_hash, s.updated_at
      FROM app.jev_context_secret s
     WHERE s.id = true
    ON CONFLICT (id) DO UPDATE
      SET secret_hash = excluded.secret_hash,
          updated_at  = excluded.updated_at;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.rpc_set_model_gateway_secret(p_secret text)
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
    RAISE EXCEPTION 'INVALID: model_gateway_secret.length' USING errcode = '22023';
  END IF;

  INSERT INTO app.model_gateway_secret (id, secret_hash, updated_at)
  VALUES (true, encode(pg_catalog.sha256(convert_to(p_secret, 'UTF8')), 'hex'), now())
  ON CONFLICT (id) DO UPDATE
    SET secret_hash = excluded.secret_hash,
        updated_at  = excluded.updated_at;
END;
$$;

COMMENT ON FUNCTION app.rpc_set_model_gateway_secret(text) IS
  'AP-70a: Ops-Setup, NICHT Teil des Anfragepfads. Nachfolger von app.rpc_set_jev_context_secret. '
  'Nur service_role. Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_set_model_gateway_secret(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_set_model_gateway_secret(text) TO service_role;

CREATE OR REPLACE FUNCTION app._mg_secret_ok(p_secret text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT p_secret IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM app.model_gateway_secret s
        WHERE s.id = true
          AND s.secret_hash = encode(pg_catalog.sha256(convert_to(p_secret, 'UTF8')), 'hex')
     );
$$;

COMMENT ON FUNCTION app._mg_secret_ok(text) IS
  'AP-70a: Helfer fuer die Gateway-Tueren. true nur bei exaktem Treffer gegen den hinterlegten '
  'Hash. Kein direkter Aufrufweg fuer Clients. Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app._mg_secret_ok(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2b. Kompatibilitaet: app.rpc_set_jev_context_secret/app._jev_context_secret_ok
--     bleiben mit identischer Signatur bestehen, delegieren nur noch.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_set_jev_context_secret(p_secret text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT app.rpc_set_model_gateway_secret(p_secret);
$$;

COMMENT ON FUNCTION app.rpc_set_jev_context_secret(text) IS
  'AP-70a: reiner Wrapper um app.rpc_set_model_gateway_secret, Signatur/Rechte unveraendert '
  'gegenueber 44 (Kompatibilitaet fuer bestehende Aufrufer). Nur service_role.';

REVOKE EXECUTE ON FUNCTION app.rpc_set_jev_context_secret(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_set_jev_context_secret(text) TO service_role;

CREATE OR REPLACE FUNCTION app._jev_context_secret_ok(p_secret text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT app._mg_secret_ok(p_secret);
$$;

COMMENT ON FUNCTION app._jev_context_secret_ok(text) IS
  'AP-70a: reiner Wrapper um app._mg_secret_ok, Signatur unveraendert gegenueber 44 '
  '(Kompatibilitaet). Kein direkter Aufrufweg fuer Clients.';

REVOKE EXECUTE ON FUNCTION app._jev_context_secret_ok(text) FROM PUBLIC, anon, authenticated;

-- Alte Tabelle entfernen -- ab hier ist app.model_gateway_secret die einzige
-- Quelle. Der Datenuebernahme-Schritt oben lief bereits.
DROP TABLE IF EXISTS app.jev_context_secret;

-- -----------------------------------------------------------------------------
-- 3. app._mg_throttle — zaehlbasierte Drosselung je Zweck UND Team/Person
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._mg_throttle(p_purpose text, p_deny_key text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id   uuid    := app.auth_team_id();
  v_actor_id  uuid    := app.auth_person_id();
  v_config    jsonb   := app._mg_purpose_config(p_purpose);
  v_max_calls integer;
  v_window    interval;
  v_recent    integer;
BEGIN
  IF v_team_id IS NULL OR v_actor_id IS NULL OR v_config IS NULL THEN
    RAISE EXCEPTION 'RATE_LIMITED: %', p_deny_key USING ERRCODE = '55000';
  END IF;

  v_max_calls := (v_config ->> 'rate_max')::integer;
  v_window    := (v_config ->> 'rate_window')::interval;

  -- Gleiches Schluessel-Schema wie bisher (44): hashtext(team||':'||person).
  -- Serialisiert parallele Aufrufe derselben Person auf denselben Schluessel
  -- -- die zweite Transaktion wartet, bis die erste committed/zurueckrollt,
  -- und zaehlt danach die inzwischen bereits eingefuegte Zeile der ersten mit.
  -- pg_advisory_xact_lock gibt den Lock am Transaktionsende automatisch frei.
  PERFORM pg_advisory_xact_lock(hashtext(v_team_id::text || ':' || v_actor_id::text));

  SELECT count(*) INTO v_recent
    FROM app.model_call_log l
   WHERE l.team_id      = v_team_id
     AND l.actor_kind    = 'person'
     AND l.actor_id      = v_actor_id
     AND l.purpose       = p_purpose
     AND l.occurred_at   > now() - v_window;

  IF v_recent >= v_max_calls THEN
    RAISE EXCEPTION 'RATE_LIMITED: %', p_deny_key USING ERRCODE = '55000';
  END IF;
END;
$$;

COMMENT ON FUNCTION app._mg_throttle(text, text) IS
  'AP-70a: zaehlbasierte Drosselung wie Punkt 86 (44), aber je Zweck (p_purpose) UND Team/Person '
  'isoliert -- ein ausgeschoepfter Zweck blockiert einen anderen Zweck fuer dieselbe Person nicht. '
  'Obergrenze/Fenster aus app._mg_purpose_config. RATE_LIMITED (55000) bei Ueberschreitung. '
  'Serialisiert per pg_advisory_xact_lock auf denselben Schluessel wie zuvor. '
  'Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app._mg_throttle(text, text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. app._mg_open — Rollenpruefung, Subjekt-Teamzugehoerigkeit, pending-Zeile
--
--    F3/F4 (Security-Review, Fixrunde): Signatur um p_context_secret erweitert
--    (zweite, redundante Sicherung neben der jeweiligen Tuer -- falls eine
--    kuenftige Tuer, z.B. AP-70b, die Secret- oder Schalter-Pruefung vor dem
--    Aufruf vergisst). DROP zuerst, weil sich die Parameterliste aendert
--    (CREATE OR REPLACE allein wuerde einen zweiten, ueberladenen Namen
--    anlegen statt den alten zu ersetzen).
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS app._mg_open(text, uuid, text, uuid[]);

CREATE OR REPLACE FUNCTION app._mg_open(
  p_purpose         text,
  p_context_ref     uuid,
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
  v_team_id      uuid  := app.auth_team_id();
  v_actor_id     uuid  := app.auth_person_id();
  v_actor_role   app.app_role := app.denial_actor_role();
  v_config       jsonb := app._mg_purpose_config(p_purpose);
  v_allowed      jsonb;
  v_subject_ct   integer;
  v_found_ct     integer;
  v_call_id      bigint;
  v_finish_token uuid;
BEGIN
  IF v_team_id IS NULL OR v_actor_id IS NULL OR v_config IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  -- F4: redundante Pruefung von Secret UND Modul-Schalter, unabhaengig davon,
  -- ob die aufrufende Tuer sie schon geprueft hat.
  IF NOT app._mg_secret_ok(p_context_secret) THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  IF NOT app.module_enabled(v_config ->> 'flag') THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  v_allowed := v_config -> 'allowed_roles';
  IF v_actor_role IS NULL OR NOT (v_allowed ? v_actor_role::text) THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  -- F3: array_length -> cardinality (robuster bei NULL-Array), mehrdimensionale
  -- Arrays und NULL-Elemente werden explizit abgelehnt statt sich auf einen
  -- zufaelligen Seiteneffekt der Kandidaten-Zaehlung zu verlassen.
  IF p_subject_ids IS NOT NULL AND array_ndims(p_subject_ids) <> 1 THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  IF p_subject_ids IS NOT NULL AND array_position(p_subject_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
  END IF;

  v_subject_ct := coalesce(cardinality(p_subject_ids), 0);

  IF v_subject_ct = 0 THEN
    -- Leeres Array nur erlauben, wenn der Zweck das ausdruecklich zulaesst.
    IF NOT coalesce((v_config ->> 'allow_empty_subjects')::boolean, false) THEN
      RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
    END IF;
  ELSE
    -- count(DISTINCT id) statt count(*): ein doppelt uebergebenes subject_id
    -- darf die Zaehlung nicht kuenstlich erfuellen. AND p.is_active: geschredderte/
    -- inaktive Personen duerfen nicht als Subjekt durchgehen.
    SELECT count(DISTINCT p.id) INTO v_found_ct
      FROM app.persons p
     WHERE p.team_id = v_team_id
       AND p.is_active
       AND p.id = ANY (p_subject_ids);
    IF v_found_ct <> v_subject_ct THEN
      RAISE EXCEPTION 'FORBIDDEN: model_gateway.open' USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO app.model_call_log (
    team_id, purpose, actor_kind, actor_id, actor_role, context_ref,
    provider, model, rule_version, input_hash, subject_count
  )
  VALUES (
    v_team_id, p_purpose, 'person', v_actor_id, v_actor_role, p_context_ref,
    v_config ->> 'provider', v_config ->> 'model', v_config ->> 'rule_version',
    p_input_hash, v_subject_ct
  )
  RETURNING id, finish_token INTO v_call_id, v_finish_token;

  IF v_subject_ct > 0 THEN
    INSERT INTO app.model_call_subjects (call_id, team_id, person_id)
    SELECT v_call_id, v_team_id, s
      FROM unnest(p_subject_ids) AS s;
  END IF;

  RETURN jsonb_build_object(
    'call_id',      v_call_id,
    'finish_token', v_finish_token,
    'provider',     v_config ->> 'provider',
    'model',        v_config ->> 'model',
    'rule_version', v_config ->> 'rule_version'
  );
END;
$$;

COMMENT ON FUNCTION app._mg_open(text, uuid, text, uuid[], text) IS
  'AP-70a/Fixrunde (F3/F4): prueft redundant Secret UND Modul-Schalter, dass die aufrufende Rolle '
  'in allowed_roles der Zweck-Konfiguration steht und dass jede subject_id eine aktive Person im '
  'eigenen Team ist (sonst FORBIDDEN, 42501, BEVOR irgendeine Zeile entsteht). Ein leeres '
  'subject_ids-Array ist nur erlaubt, wenn die Konfiguration allow_empty_subjects setzt. Legt '
  'danach die pending-Zeile in app.model_call_log/model_call_subjects an, rule_version/provider/'
  'model aus der Konfiguration. Gibt call_id/finish_token/provider/model/rule_version zurueck. '
  'Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app._mg_open(text, uuid, text, uuid[], text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. app.rpc_finish_model_call — CREATE OR REPLACE, Signatur unveraendert.
--    Neu: result_class 'rejected'. Constraint-Name idempotent ueber
--    pg_constraint gesucht (nicht hart kodiert).
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
     AND pg_get_constraintdef(c.oid) LIKE '%result_class%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE app.model_call_log DROP CONSTRAINT %I', v_constraint_name);
  END IF;

  ALTER TABLE app.model_call_log ADD CONSTRAINT model_call_log_result_class_check
    CHECK (result_class IN
      ('pending', 'ok', 'partial', 'invalid', 'timeout', 'rate_limited', 'http_error', 'rejected'));
END;
$$;

COMMENT ON CONSTRAINT model_call_log_result_class_check ON app.model_call_log IS
  'AP-70a: result_class-Werteliste, erweitert um "rejected" (Ausgangswaechter hat verworfen, '
  'AP-70b). Constraint-Name bewusst fest vergeben, das vorherige (Migrations-generierte) '
  'Constraint wird zuvor idempotent ueber pg_constraint gesucht und gedroppt.';

CREATE OR REPLACE FUNCTION app.rpc_finish_model_call(
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
     ('ok', 'partial', 'invalid', 'timeout', 'rate_limited', 'http_error', 'rejected') THEN
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
     AND finish_token = p_finish_token
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN app.deny('model_call_log.finish', 'FORBIDDEN: model_call_log.finish');
  END IF;

  RETURN jsonb_build_object('call_id', v_id, 'result_class', p_result_class);
END;
$$;

COMMENT ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) IS
  'AP-70a: schliesst eine eigene pending-Zeile in app.model_call_log ab (eigene Person, eigenes '
  'Team, juenger als 5 Minuten, korrektes finish_token). result_class jetzt zusaetzlich '
  '"rejected" (Ausgangswaechter hat verworfen, AP-70b). Alles andere deny/22023 wie zuvor (44). '
  'Signatur unveraendert. Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_finish_model_call(bigint, text, integer, uuid) TO authenticated;

-- public-Tuer: Signatur unveraendert -> CREATE OR REPLACE reicht.
CREATE OR REPLACE FUNCTION public.rpc_finish_model_call(p_call_id bigint, p_result_class text, p_latency_ms integer, p_finish_token uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_finish_model_call(p_call_id, p_result_class, p_latency_ms, p_finish_token);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) IS
  'API-Tuer fuer app.rpc_finish_model_call. Invoker, nur authenticated. AP-70a.';

REVOKE EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_finish_model_call(bigint, text, integer, uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_squad_check_jev_context — CREATE OR REPLACE, Signatur
--    unveraendert. Rumpf delegiert jetzt an die _mg_*-Helfer.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_squad_check_jev_context(
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
  c_purpose      CONSTANT text := 'ap69_squad_check';
  v_config       jsonb;
  v_team_id      uuid;
  v_session      app.training_sessions%rowtype;
  v_rows         jsonb;
  v_ctx          jsonb;
  v_cands        jsonb;
  v_refs         jsonb;
  v_subject_ids  uuid[];
  v_hash_in      jsonb;
  v_hash         text;
  v_count        integer;
  v_open         jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  -- Punkt 87 (Nachtrag 2026-09-29, unveraendert): ohne korrektes Server-Secret
  -- keine Zeile, kein Kontext -- schliesst den Phantom-Zeilen-Weg (direkter
  -- Aufruf ohne Next.js). Bewusst VOR jedem weiteren Datenzugriff.
  IF NOT app._mg_secret_ok(p_context_secret) THEN
    RETURN app.deny('squad_check.jev_context', 'FORBIDDEN: squad_check.jev_context');
  END IF;

  v_config  := app._mg_purpose_config(c_purpose);
  v_team_id := app.auth_team_id();

  IF p_session_id IS NOT NULL THEN
    SELECT * INTO v_session FROM app.training_sessions
     WHERE id = p_session_id AND team_id = v_team_id;
    IF v_session.id IS NULL THEN
      RAISE EXCEPTION 'NOT_FOUND: training_sessions' USING errcode = 'P0002';
    END IF;
  END IF;

  IF NOT app.module_enabled(v_config ->> 'flag') THEN
    RAISE EXCEPTION 'MODULE_DISABLED' USING errcode = '55000';
  END IF;

  -- Nur gespeicherte Einheiten: ein Entwurf hat keine Einheit, an die ein
  -- Protokolleintrag (context_ref) und ein Wegklick (j1) gebunden werden kann.
  IF p_session_id IS NULL THEN
    RETURN jsonb_build_object('call_id', NULL, 'candidates', '[]'::jsonb, 'refs', '[]'::jsonb);
  END IF;

  -- duration_min/planned_intensity kommen (unveraendert seit Punkt 86
  -- Root-Fix, 44) aus der gespeicherten Session, nicht aus den Parametern.
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
         COALESCE(array_agg(person_id::uuid ORDER BY ref), ARRAY[]::uuid[]),
         count(*)
    INTO v_cands, v_refs, v_hash_in, v_subject_ids, v_count
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
  v_hash := encode(pg_catalog.sha256(convert_to(
              jsonb_build_object('rule_version', v_config ->> 'rule_version', 'session', v_ctx, 'athletes', v_hash_in)::text,
              'UTF8')), 'hex');

  PERFORM app._mg_throttle(c_purpose, 'squad_check.jev_context');

  v_open := app._mg_open(c_purpose, p_session_id, v_hash, v_subject_ids, p_context_secret);

  RETURN jsonb_build_object(
    -- F1 (Security-Review, Fixrunde): -> statt ->> -- call_id MUSS eine JSON-
    -- Zahl bleiben (lib/ai/gateway/run.ts prueft typeof === "number"), ->>
    -- haette sie in einen String verwandelt. finish_token/provider/model/
    -- rule_version sind Strings, dort bleibt ->> richtig.
    'call_id',      v_open -> 'call_id',
    'finish_token', v_open ->> 'finish_token',
    'provider',     v_open ->> 'provider',
    'model',        v_open ->> 'model',
    'rule_version', v_open ->> 'rule_version',
    'session',      v_ctx,
    'candidates',   v_cands,
    'refs',         v_refs
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) IS
  'AP-70a: einzige Quelle der JEV-Eingaben, Signatur unveraendert gegenueber 44. Rumpf delegiert '
  'an app._mg_throttle/app._mg_open statt eigener Drosselungs-/Insert-Logik, Pruefreihenfolge '
  'exakt wie zuvor: Team -> Staff -> Secret -> Session -> Schalter -> Kandidaten -> Hash -> '
  'Drosselung -> Oeffnen. Provider/Modell/Regelversion/Schalter-Name aus '
  'app._mg_purpose_config(''ap69_squad_check''), Werte identisch zu vorher. '
  'Siehe backend/47_model_gateway_core.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_squad_check_jev_context(uuid, smallint, smallint, text) TO authenticated;

-- public-Tuer: Signatur unveraendert -> CREATE OR REPLACE reicht.
CREATE OR REPLACE FUNCTION public.rpc_squad_check_jev_context(
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
  'API-Tuer fuer app.rpc_squad_check_jev_context. Invoker, nur authenticated. AP-70a.';

REVOKE EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_squad_check_jev_context(uuid, smallint, smallint, text) TO authenticated, service_role;
