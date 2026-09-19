-- =============================================================================
-- 09_rpcs.sql — 11 RPCs aus Spec §7 (Medizin-Gate, ADR-009/ADR-011)

-- =============================================================================

-- =============================================================================
-- 0. CLEAN SLATE (idempotent)
-- =============================================================================

DROP POLICY IF EXISTS access_log_select_self ON app.access_log;
DROP POLICY IF EXISTS access_log_insert_definer ON app.access_log;
DROP POLICY IF EXISTS readiness_scores_select_team ON app.readiness_scores;
DROP POLICY IF EXISTS readiness_scores_select_self ON app.readiness_scores;
DROP POLICY IF EXISTS readiness_scores_insert_definer ON app.readiness_scores;
DROP POLICY IF EXISTS load_deviations_select_team ON app.load_deviations;
DROP POLICY IF EXISTS load_deviations_select_self ON app.load_deviations;
DROP POLICY IF EXISTS load_deviations_update_medical ON app.load_deviations;
DROP POLICY IF EXISTS daily_checkins_select_team ON app.daily_checkins;
DROP POLICY IF EXISTS daily_checkins_select_self ON app.daily_checkins;
DROP POLICY IF EXISTS daily_checkins_insert_self ON app.daily_checkins;

DROP TRIGGER IF EXISTS readiness_scores_audit ON app.readiness_scores;
DROP TRIGGER IF EXISTS load_deviations_audit ON app.load_deviations;
DROP TRIGGER IF EXISTS daily_checkins_audit ON app.daily_checkins;

DROP FUNCTION IF EXISTS app.log_denial(text);
DROP FUNCTION IF EXISTS app.access_log_write(uuid, text, text, date);
DROP FUNCTION IF EXISTS app.denial_actor_role();

DROP FUNCTION IF EXISTS app.rpc_get_my_roles();
DROP FUNCTION IF EXISTS app.rpc_list_team_members();
DROP FUNCTION IF EXISTS app.rpc_check_ins_medical(date, date);
DROP FUNCTION IF EXISTS app.rpc_readiness_full(uuid, date, date);
DROP FUNCTION IF EXISTS app.rpc_release_deviation(uuid, text);
DROP FUNCTION IF EXISTS app.rpc_get_clearance(uuid);
DROP FUNCTION IF EXISTS app.rpc_set_clearance(uuid, app.app_clearance, text, date, date);
DROP FUNCTION IF EXISTS app.rpc_propose_clearance(uuid, app.app_clearance, text);
DROP FUNCTION IF EXISTS app.rpc_get_my_access_log(date, date);
DROP FUNCTION IF EXISTS app.rpc_export_my_data();
DROP FUNCTION IF EXISTS app.rpc_shred_person(uuid);
DROP FUNCTION IF EXISTS app.rpc_admin_denials(date, date);

DROP TABLE IF EXISTS app.access_log CASCADE;
DROP TABLE IF EXISTS app.readiness_scores CASCADE;
DROP TABLE IF EXISTS app.load_deviations CASCADE;
DROP TABLE IF EXISTS app.daily_checkins CASCADE;

DROP TYPE IF EXISTS app.app_deviation_state CASCADE;
DROP TYPE IF EXISTS app.app_readiness_band CASCADE;


-- =============================================================================
-- 1. TYPES
-- =============================================================================

CREATE TYPE app.app_deviation_state AS ENUM ('unreviewed', 'released', 'dismissed');
CREATE TYPE app.app_readiness_band AS ENUM ('low', 'moderate', 'high');


-- =============================================================================
-- 2. TABLES (fehlende Tabellen für RPCs, falls nicht vorhanden)
-- =============================================================================

-- daily_checkins (Tagescheckin mit Body Map - medizinische Komponente)
CREATE TABLE IF NOT EXISTS app.daily_checkins (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id         uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id       uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  date            date NOT NULL,
  sleep_duration_min  numeric(5,2),
  sleep_quality   smallint CHECK (sleep_quality BETWEEN 1 AND 10),
  recovery        smallint CHECK (recovery BETWEEN 1 AND 10),
  energy          smallint CHECK (energy BETWEEN 1 AND 10),
  mental_stress   smallint CHECK (mental_stress BETWEEN 1 AND 10),
  mental_mood     smallint CHECK (mental_mood BETWEEN 1 AND 10),
  mental_motivation smallint CHECK (mental_motivation BETWEEN 1 AND 10),
  training_readiness smallint CHECK (training_readiness BETWEEN 1 AND 10),
  body_map        jsonb,  -- Schmerzregion + Wert (medizinisch!)
  pain_max        smallint,
  submitted_at    timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz,
  UNIQUE (person_id, date)
);

-- readiness_scores (Score mit Band - ADR-011 P3-Gating)
CREATE TABLE IF NOT EXISTS app.readiness_scores (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id         uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id       uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  date            date NOT NULL,
  score_total     numeric(4,1) NOT NULL,    -- Medizin und self NIE fuer Staff
  band            app.app_readiness_band NOT NULL,  -- Staff-sichtbar
  factors         jsonb NOT NULL,           -- Komponenten, medizinische Komponente NIE fuer Staff
  computed_at     timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id, date)
);

-- load_deviations (Lastabweichungen - Freigabe-Workflow)
CREATE TABLE IF NOT EXISTS app.load_deviations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id         uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id       uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  date            date NOT NULL,
  deviation       numeric(5,2) NOT NULL,
  state           app.app_deviation_state NOT NULL DEFAULT 'unreviewed',
  reviewed_by     uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  reviewed_at     timestamptz,
  released_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id, date)
);

-- access_log (wer hat wann meine Daten gesehen - DSGVO)
CREATE TABLE IF NOT EXISTS app.access_log (
  id              bigserial PRIMARY KEY,
  team_id         uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  subject_id      uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  actor_id        uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  actor_role      app.app_role NOT NULL,
  resource        text NOT NULL,
  action          text NOT NULL CHECK (action IN ('read', 'write', 'export')),
  scope_date      date,
  occurred_at     timestamptz NOT NULL DEFAULT now()
);


-- =============================================================================
-- 3. INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_daily_checkins_team_id ON app.daily_checkins(team_id);
CREATE INDEX IF NOT EXISTS idx_daily_checkins_person_id ON app.daily_checkins(person_id);
CREATE INDEX IF NOT EXISTS idx_readiness_scores_team_id ON app.readiness_scores(team_id);
CREATE INDEX IF NOT EXISTS idx_readiness_scores_person_id ON app.readiness_scores(person_id);
CREATE INDEX IF NOT EXISTS idx_load_deviations_team_id ON app.load_deviations(team_id);
CREATE INDEX IF NOT EXISTS idx_load_deviations_person_id ON app.load_deviations(person_id);
CREATE INDEX IF NOT EXISTS idx_access_log_subject_id ON app.access_log(subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_access_log_team_id ON app.access_log(team_id);


-- =============================================================================
-- 4. RLS ENABLE + FORCE
-- =============================================================================

ALTER TABLE app.daily_checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.daily_checkins FORCE ROW LEVEL SECURITY;

ALTER TABLE app.readiness_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.readiness_scores FORCE ROW LEVEL SECURITY;

ALTER TABLE app.load_deviations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.load_deviations FORCE ROW LEVEL SECURITY;

ALTER TABLE app.access_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.access_log FORCE ROW LEVEL SECURITY;


-- =============================================================================
-- 5. AUDIT TRIGGER (fuer readiness_scores, load_deviations, daily_checkins)
-- =============================================================================

CREATE OR REPLACE FUNCTION app.denial_actor_role()
RETURNS app.app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'app_role')::app.app_role;
$$;

-- Trigger fuer readiness_scores
CREATE TRIGGER readiness_scores_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.readiness_scores
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();

-- Trigger fuer load_deviations
CREATE TRIGGER load_deviations_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.load_deviations
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();

-- Trigger fuer daily_checkins
CREATE TRIGGER daily_checkins_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.daily_checkins
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();


-- =============================================================================
-- 6. SPALTENRECHTE / GRANTS
-- =============================================================================

GRANT ALL ON ALL TABLES IN SCHEMA app TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA app TO service_role;

-- daily_checkins: body_map und pain_max NICHT fuer Staff (nur medical/self)
GRANT SELECT, INSERT, UPDATE ON app.daily_checkins TO authenticated;
REVOKE SELECT ON app.daily_checkins FROM authenticated;
GRANT SELECT (id, team_id, person_id, date, sleep_duration_min, sleep_quality,
              recovery, energy, mental_stress, mental_mood, mental_motivation,
              training_readiness, submitted_at, created_at, updated_at)
  ON app.daily_checkins TO authenticated;

-- readiness_scores: score_total und factors NICHT fuer Staff
GRANT SELECT, INSERT, UPDATE ON app.readiness_scores TO authenticated;
REVOKE SELECT ON app.readiness_scores FROM authenticated;
GRANT SELECT (id, team_id, person_id, date, band, computed_at, created_at)
  ON app.readiness_scores TO authenticated;

-- load_deviations: alle in Team sehen released, nur medical+self sehen unreviewed
GRANT SELECT, INSERT, UPDATE ON app.load_deviations TO authenticated;

-- access_log: nur self lesbar
GRANT INSERT ON app.access_log TO authenticated;


-- =============================================================================
-- 7. RLS POLICIES
-- =============================================================================

-- daily_checkins
CREATE POLICY daily_checkins_select_team ON app.daily_checkins
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY daily_checkins_select_self ON app.daily_checkins
  FOR SELECT TO authenticated
  USING (person_id = app.auth_person_id());

CREATE POLICY daily_checkins_insert_self ON app.daily_checkins
  FOR INSERT TO authenticated
  WITH CHECK (person_id = app.auth_person_id() AND team_id = app.auth_team_id());

-- readiness_scores
CREATE POLICY readiness_scores_select_team ON app.readiness_scores
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY readiness_scores_select_self ON app.readiness_scores
  FOR SELECT TO authenticated
  USING (person_id = app.auth_person_id());

CREATE POLICY readiness_scores_insert_definer ON app.readiness_scores
  FOR INSERT TO authenticated
  WITH CHECK (current_user = 'service_role' AND team_id = app.auth_team_id());

-- load_deviations
CREATE POLICY load_deviations_select_team ON app.load_deviations
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY load_deviations_select_self ON app.load_deviations
  FOR SELECT TO authenticated
  USING (person_id = app.auth_person_id());

CREATE POLICY load_deviations_update_medical ON app.load_deviations
  FOR UPDATE TO authenticated
  USING (app.auth_is_medical() AND team_id = app.auth_team_id())
  WITH CHECK (app.auth_is_medical() AND team_id = app.auth_team_id());

-- access_log
CREATE POLICY access_log_select_self ON app.access_log
  FOR SELECT TO authenticated
  USING (subject_id = app.auth_person_id() AND team_id = app.auth_team_id());

CREATE POLICY access_log_insert_definer ON app.access_log
  FOR INSERT TO authenticated
  WITH CHECK (team_id = app.auth_team_id());


-- =============================================================================
-- 8. HELPER FUER DENY-PROTOKOLLIERUNG
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

CREATE OR REPLACE FUNCTION app.log_denial(p_resource text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, public, auth, pg_temp
AS $$
DECLARE
  v_sql text;
  v_team_id uuid;
  v_actor_id uuid;
  v_actor_role app.app_role;
BEGIN
  v_team_id := app.auth_team_id();
  v_actor_id := app.auth_person_id();
  v_actor_role := app.denial_actor_role();

  -- Ohne bestaetigtes Team (anon, geshreddet, Rolle entzogen) gibt es kein
  -- Team, dem die Ablehnung zugeordnet werden kann. Ohne diesen Ausstieg
  -- scheitert der INSERT an team_id NOT NULL und der Aufrufer bekaeme 23502
  -- statt FORBIDDEN.
  IF v_team_id IS NULL THEN
    RETURN;
  END IF;

  -- In-transaktionaler Fallback (falls dblink nicht verfuegbar)
  INSERT INTO app.access_denials (team_id, actor_id, actor_role, resource, occurred_at)
  VALUES (v_team_id, v_actor_id, v_actor_role, p_resource, now());
END;
$$;

REVOKE EXECUTE ON FUNCTION app.log_denial(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app.log_denial(text) TO service_role;


-- =============================================================================
-- 9. RPCs
-- =============================================================================

-- 9.1 rpc_get_my_roles()
CREATE OR REPLACE FUNCTION app.rpc_get_my_roles()
RETURNS TABLE(person_id uuid, team_id uuid, roles jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    app.auth_person_id(),
    app.auth_team_id(),
    COALESCE(
      (SELECT jsonb_agg(ra.role) FROM app.role_assignments ra
       WHERE ra.person_id = app.auth_person_id()
         AND ra.team_id = app.auth_team_id()
         AND ra.valid_from <= current_date
         AND (ra.valid_to IS NULL OR ra.valid_to >= current_date)),
      '[]'::jsonb
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_get_my_roles() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_get_my_roles() TO authenticated;


-- 9.2 rpc_list_team_members()
CREATE OR REPLACE FUNCTION app.rpc_list_team_members()
RETURNS TABLE(
  id uuid,
  display_name text,
  person_position text,
  clearance_status app.app_clearance
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Rolle pruefen (erste Anweisung)
  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')) THEN
    PERFORM app.log_denial('persons.list');
    RAISE EXCEPTION 'FORBIDDEN: persons.list' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.person_position,
    COALESCE(mc.status, 'full'::app.app_clearance) AS clearance_status
  FROM app.persons p
  LEFT JOIN app.medical_clearances mc ON mc.person_id = p.id
    AND mc.team_id = app.auth_team_id()
    AND mc.valid_from <= current_date
    AND (mc.valid_to IS NULL OR mc.valid_to >= current_date)
  WHERE p.team_id = app.auth_team_id()
    AND p.is_active = true;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_list_team_members() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_list_team_members() TO authenticated;


-- 9.3 rpc_check_ins_medical(p_from, p_to)
CREATE OR REPLACE FUNCTION app.rpc_check_ins_medical(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
)
RETURNS SETOF app.daily_checkins
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    PERFORM app.log_denial('daily_checkins.body_map');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.body_map' USING errcode = '42501';
  END IF;

  IF NOT (app.auth_is_medical() OR app.auth_person_id() IS NOT NULL) THEN
    PERFORM app.log_denial('daily_checkins.medical');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.medical' USING errcode = '42501';
  END IF;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(),
    app.auth_person_id(),
    app.auth_person_id(),
    app.denial_actor_role(),
    'daily_checkins.body_map',
    'read',
    COALESCE(p_from, current_date)
  );

  RETURN QUERY
  SELECT dc.* FROM app.daily_checkins dc
  WHERE dc.team_id = app.auth_team_id()
    AND (p_from IS NULL OR dc.date >= p_from)
    AND (p_to IS NULL OR dc.date <= p_to)
    AND (
      app.auth_is_medical()
      OR dc.person_id = app.auth_person_id()
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_check_ins_medical(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_check_ins_medical(date, date) TO authenticated;


-- 9.4 rpc_readiness_full(p_person_id, p_from, p_to)
CREATE OR REPLACE FUNCTION app.rpc_readiness_full(
  p_person_id uuid,
  p_from      date DEFAULT NULL,
  p_to        date DEFAULT NULL
)
RETURNS SETOF app.readiness_scores
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF app.auth_is_staff() OR app.auth_has_role('admin') THEN
    PERFORM app.log_denial('readiness_scores.score_total');
    RAISE EXCEPTION 'FORBIDDEN: readiness_scores.score_total' USING errcode = '42501';
  END IF;

  IF NOT (app.auth_is_medical() OR app.auth_person_id() = p_person_id) THEN
    PERFORM app.log_denial('readiness_scores.full');
    RAISE EXCEPTION 'FORBIDDEN: readiness_scores.full' USING errcode = '42501';
  END IF;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
  VALUES (
    app.auth_team_id(),
    p_person_id,
    app.auth_person_id(),
    app.denial_actor_role(),
    'readiness_scores.score_total',
    'read',
    COALESCE(p_from, current_date)
  );

  RETURN QUERY
  SELECT rs.* FROM app.readiness_scores rs
  WHERE rs.team_id = app.auth_team_id()
    AND rs.person_id = p_person_id
    AND (p_from IS NULL OR rs.date >= p_from)
    AND (p_to IS NULL OR rs.date <= p_to);
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date) TO authenticated;


-- 9.5 rpc_release_deviation(p_deviation_id, p_decision)
CREATE OR REPLACE FUNCTION app.rpc_release_deviation(
  p_deviation_id uuid,
  p_decision     text
)
RETURNS app.load_deviations
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.load_deviations;
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF NOT (app.auth_has_role('physio') OR app.auth_has_role('doctor')) THEN
    PERFORM app.log_denial('load_deviations.release');
    RAISE EXCEPTION 'FORBIDDEN: load_deviations.release' USING errcode = '42501';
  END IF;

  UPDATE app.load_deviations
  SET state = CASE WHEN p_decision = 'release' THEN 'released'::app.app_deviation_state
                   WHEN p_decision = 'dismiss' THEN 'dismissed'::app.app_deviation_state
                   ELSE state END,
      reviewed_by = app.auth_person_id(),
      reviewed_at = now(),
      released_at = CASE WHEN p_decision = 'release' THEN now() ELSE released_at END
  WHERE id = p_deviation_id
    AND team_id = app.auth_team_id()
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deviation not found';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_release_deviation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_release_deviation(uuid, text) TO authenticated;


-- 9.6 rpc_get_clearance(p_person_id)
CREATE OR REPLACE FUNCTION app.rpc_get_clearance(p_person_id uuid)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!)
  IF NOT (app.auth_is_staff() OR app.auth_is_medical() OR app.auth_has_role('admin')
          OR app.auth_person_id() = p_person_id) THEN
    PERFORM app.log_denial('medical_clearances.get');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.get' USING errcode = '42501';
  END IF;

  -- Access log (medizinische Ressource)
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(),
    p_person_id,
    app.auth_person_id(),
    app.denial_actor_role(),
    'medical_clearances',
    'read'
  );

  SELECT * INTO v_row FROM app.medical_clearances
  WHERE person_id = p_person_id
    AND team_id = app.auth_team_id()
    AND valid_from <= current_date
    AND (valid_to IS NULL OR valid_to >= current_date)
  ORDER BY valid_from DESC
  LIMIT 1;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_get_clearance(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_get_clearance(uuid) TO authenticated;


-- 9.7 rpc_set_clearance(p_person_id, p_status, p_load_note, p_valid_from, p_valid_to)
CREATE OR REPLACE FUNCTION app.rpc_set_clearance(
  p_person_id   uuid,
  p_status      app.app_clearance,
  p_load_note   text DEFAULT NULL,
  p_valid_from  date DEFAULT current_date,
  p_valid_to    date DEFAULT NULL
)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!) - NUR doctor
  IF NOT app.auth_has_role('doctor') THEN
    PERFORM app.log_denial('medical_clearances.set');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.set (only doctor)' USING errcode = '42501';
  END IF;

  INSERT INTO app.medical_clearances (
    team_id, person_id, status, load_note, valid_from, valid_to, set_by, set_by_role
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_load_note, p_valid_from, p_valid_to,
    app.auth_person_id(), 'doctor'::app.app_role
  )
  RETURNING * INTO v_row;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (
    app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
    'medical_clearances', 'write'
  );

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_set_clearance(uuid, app.app_clearance, text, date, date) TO authenticated;


-- 9.8 rpc_propose_clearance(p_person_id, p_status, p_rationale)
CREATE OR REPLACE FUNCTION app.rpc_propose_clearance(
  p_person_id uuid,
  p_status    app.app_clearance,
  p_rationale text DEFAULT NULL
)
RETURNS app.medical_clearances
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.medical_clearances;
BEGIN
  -- Rolle pruefen (erste Anweisung!) - NUR physio
  IF NOT app.auth_has_role('physio') THEN
    PERFORM app.log_denial('medical_clearances.propose');
    RAISE EXCEPTION 'FORBIDDEN: medical_clearances.propose (only physio)' USING errcode = '42501';
  END IF;

  INSERT INTO app.medical_clearances (
    team_id, person_id, status, load_note, valid_from, valid_to,
    set_by, set_by_role, proposed_by
  ) VALUES (
    app.auth_team_id(), p_person_id, p_status, p_rationale, current_date, NULL,
    app.auth_person_id(), 'physio'::app.app_role, app.auth_person_id()
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_propose_clearance(uuid, app.app_clearance, text) TO authenticated;


-- 9.9 rpc_get_my_access_log(p_from, p_to)
CREATE OR REPLACE FUNCTION app.rpc_get_my_access_log(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
)
RETURNS SETOF app.access_log
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Nur self
  IF app.auth_person_id() IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: auth required' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT al.* FROM app.access_log al
  WHERE al.subject_id = app.auth_person_id()
    AND al.team_id = app.auth_team_id()
    AND (p_from IS NULL OR al.occurred_at::date >= p_from)
    AND (p_to IS NULL OR al.occurred_at::date <= p_to)
  ORDER BY al.occurred_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_get_my_access_log(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_get_my_access_log(date, date) TO authenticated;


-- 9.10 rpc_export_my_data()
CREATE OR REPLACE FUNCTION app.rpc_export_my_data()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  v_result    jsonb;
BEGIN
  v_person_id := app.auth_person_id();
  v_team_id := app.auth_team_id();

  -- Nur self oder admin
  IF v_person_id IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: auth required' USING errcode = '42501';
  END IF;

  SELECT jsonb_build_object(
    'person', (SELECT to_jsonb(p.*) FROM app.persons p WHERE p.id = v_person_id),
    'daily_checkins', COALESCE((SELECT jsonb_agg(to_jsonb(dc.*)) FROM app.daily_checkins dc WHERE dc.person_id = v_person_id AND dc.team_id = v_team_id), '[]'::jsonb),
    'readiness_scores', COALESCE((SELECT jsonb_agg(to_jsonb(rs.*)) FROM app.readiness_scores rs WHERE rs.person_id = v_person_id AND rs.team_id = v_team_id), '[]'::jsonb),
    'load_deviations', COALESCE((SELECT jsonb_agg(to_jsonb(ld.*)) FROM app.load_deviations ld WHERE ld.person_id = v_person_id AND ld.team_id = v_team_id), '[]'::jsonb),
    'medical_clearances', COALESCE((SELECT jsonb_agg(to_jsonb(mc.*)) FROM app.medical_clearances mc WHERE mc.person_id = v_person_id AND mc.team_id = v_team_id), '[]'::jsonb),
    'access_log', COALESCE((SELECT jsonb_agg(to_jsonb(al.*)) FROM app.access_log al WHERE al.subject_id = v_person_id AND al.team_id = v_team_id), '[]'::jsonb),
    'exported_at', now()
  ) INTO v_result;

  -- Access log
  INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
  VALUES (v_team_id, v_person_id, v_person_id, app.denial_actor_role(), 'data_export', 'export');

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_export_my_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_export_my_data() TO authenticated;


-- 9.11 rpc_shred_person(p_person_id)
CREATE OR REPLACE FUNCTION app.rpc_shred_person(p_person_id uuid)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Nur admin
  IF NOT app.auth_has_role('admin') THEN
    PERFORM app.log_denial('persons.shred');
    RAISE EXCEPTION 'FORBIDDEN: persons.shred (only admin)' USING errcode = '42501';
  END IF;

  -- Crypto-Shredding: PII-Zeiger loeschen (hier: display_name anonymisieren)
  UPDATE app.persons
  SET display_name = 'SCRAPED-' || substr(md5(random()::text), 1, 8),
      auth_user_id = NULL,
      birth_date = NULL,
      is_active = false,
      updated_at = now()
  WHERE id = p_person_id
    AND team_id = app.auth_team_id();

  -- Audit log
  INSERT INTO app.audit_log (team_id, table_name, row_id, operation, actor_id, actor_role, old_row, new_row)
  VALUES (
    app.auth_team_id(), 'persons', p_person_id, 'DELETE',
    app.auth_person_id(), 'admin'::app.app_role,
    NULL, jsonb_build_object('action', 'crypto_shred', 'person_id', p_person_id)
  );

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_shred_person(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_shred_person(uuid) TO authenticated;


-- 9.12 rpc_admin_denials(p_from, p_to)
CREATE OR REPLACE FUNCTION app.rpc_admin_denials(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
)
RETURNS SETOF app.access_denials
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  -- Nur admin
  IF NOT app.auth_has_role('admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: access_denials.admin' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT ad.* FROM app.access_denials ad
  WHERE ad.team_id = app.auth_team_id()
    AND (p_from IS NULL OR ad.occurred_at::date >= p_from)
    AND (p_to IS NULL OR ad.occurred_at::date <= p_to)
  ORDER BY ad.occurred_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_admin_denials(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_admin_denials(date, date) TO authenticated;


-- =============================================================================
-- 10. RPC: Supabase-Client-Helpers (Public-facing Views/Functions)
-- =============================================================================

-- Band-View fuer Staff (nur Band, nie Score)
CREATE OR REPLACE VIEW app.v_readiness_staff WITH (security_invoker = true) AS
SELECT id, team_id, person_id, date, band, computed_at, created_at
FROM app.readiness_scores;

-- Checkin-View fuer Staff (kein body_map)
CREATE OR REPLACE VIEW app.v_daily_checkins_staff WITH (security_invoker = true) AS
SELECT id, team_id, person_id, date, sleep_duration_min, sleep_quality, recovery,
       energy, mental_stress, mental_mood, mental_motivation, training_readiness,
       submitted_at, created_at, updated_at
FROM app.daily_checkins;
