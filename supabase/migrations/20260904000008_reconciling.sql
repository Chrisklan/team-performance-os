-- =============================================================================
-- 08_reconciling.sql — Rollen-Medizin-Gate (AP13b-Schritt-1)
-- ADR-001 Silo: team_id als einzige Scoping-Ebene.
-- Idempotent: DROP IF EXISTS vor jedem CREATE.
-- =============================================================================


-- =============================================================================
-- 0. STUBS: Leere Hilfs-Tabellen, damit DROP POLICY/TRIGGER IF EXISTS
--    nicht gegen fehlendes Relation-Target crasht.
--    Werden gleich durch DROP TABLE IF EXISTS ... CASCADE ersetzt.
-- =============================================================================
CREATE TABLE IF NOT EXISTS app.persons (id uuid);
CREATE TABLE IF NOT EXISTS app.role_assignments (id uuid);
CREATE TABLE IF NOT EXISTS app.medical_clearances (id uuid);
CREATE TABLE IF NOT EXISTS app.audit_log (id uuid);
CREATE TABLE IF NOT EXISTS app.access_denials (id uuid);

-- =============================================================================
-- 0. CLEAN SLATE für app.* (idempotent re-run)
-- Policies müssen vor Funktionen gedroppt, Trigger vor Tabellen.
-- =============================================================================

DROP POLICY IF EXISTS persons_select_team ON app.persons;
DROP POLICY IF EXISTS persons_insert_admin ON app.persons;
DROP POLICY IF EXISTS persons_update_admin ON app.persons;
DROP POLICY IF EXISTS role_assignments_select_team ON app.role_assignments;
DROP POLICY IF EXISTS role_assignments_insert_admin ON app.role_assignments;
DROP POLICY IF EXISTS role_assignments_update_admin ON app.role_assignments;
DROP POLICY IF EXISTS medical_clearances_select_team ON app.medical_clearances;
DROP POLICY IF EXISTS medical_clearances_insert_doctor ON app.medical_clearances;
DROP POLICY IF EXISTS medical_clearances_update_doctor ON app.medical_clearances;
DROP POLICY IF EXISTS audit_log_select_admin ON app.audit_log;
DROP POLICY IF EXISTS access_denials_select_admin ON app.access_denials;

DROP TRIGGER IF EXISTS medical_clearances_audit ON app.medical_clearances;
DROP TRIGGER IF EXISTS persons_audit ON app.persons;
DROP FUNCTION IF EXISTS app.audit_log_trigger();
DROP FUNCTION IF EXISTS app.auth_person_id();
DROP FUNCTION IF EXISTS app.auth_team_id();
DROP FUNCTION IF EXISTS app.auth_has_role(app.app_role);
DROP FUNCTION IF EXISTS app.auth_in_team(uuid);
DROP FUNCTION IF EXISTS app.auth_is_staff();
DROP FUNCTION IF EXISTS app.auth_is_medical();

DROP TABLE IF EXISTS app.access_denials CASCADE;
DROP TABLE IF EXISTS app.audit_log CASCADE;
DROP TABLE IF EXISTS app.medical_clearances CASCADE;
DROP TABLE IF EXISTS app.role_assignments CASCADE;
DROP TABLE IF EXISTS app.persons CASCADE;
DROP TABLE IF EXISTS app.teams CASCADE;

DROP TYPE IF EXISTS app.app_clearance CASCADE;
DROP TYPE IF EXISTS app.app_role CASCADE;


-- =============================================================================
-- 1. Schema + Types
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS app;
GRANT USAGE ON SCHEMA app TO authenticated, anon, service_role;

CREATE TYPE app.app_role AS ENUM ('player', 'coach', 'athletic_coach', 'physio', 'doctor', 'admin');
CREATE TYPE app.app_clearance AS ENUM ('full', 'limited', 'individual', 'blocked');


-- =============================================================================
-- 2. Tabellen
-- =============================================================================

CREATE TABLE app.teams (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  timezone    text NOT NULL DEFAULT 'Europe/Berlin',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.persons (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  auth_user_id  uuid UNIQUE,
  display_name  text NOT NULL,
  person_position  text,
  shirt_number  smallint,
  birth_date    date,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.role_assignments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id   uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  role        app.app_role NOT NULL,
  valid_from  timestamptz NOT NULL DEFAULT now(),
  valid_to    timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_assignments_valid_range CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE app.medical_clearances (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  status        app.app_clearance NOT NULL,
  load_note     text,
  valid_from    timestamptz NOT NULL DEFAULT now(),
  valid_to      timestamptz,
  set_by        uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  set_by_role   app.app_role NOT NULL,
  proposed_by   uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT medical_clearances_valid_range CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE app.audit_log (
  id           bigserial PRIMARY KEY,
  team_id      uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  table_name   text NOT NULL,
  row_id       uuid NOT NULL,
  operation    text NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
  actor_id     uuid,
  actor_role   app.app_role,
  old_row      jsonb,
  new_row      jsonb,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.access_denials (
  id           bigserial PRIMARY KEY,
  team_id      uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  actor_id     uuid,
  actor_role   app.app_role,
  resource     text NOT NULL,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_persons_team_id ON app.persons(team_id);
CREATE INDEX idx_role_assignments_team_id ON app.role_assignments(team_id);
CREATE INDEX idx_role_assignments_person_id ON app.role_assignments(person_id);
CREATE INDEX idx_medical_clearances_team_id ON app.medical_clearances(team_id);
CREATE INDEX idx_medical_clearances_person_id ON app.medical_clearances(person_id);
CREATE INDEX idx_audit_log_team_id ON app.audit_log(team_id);
CREATE INDEX idx_access_denials_team_id ON app.access_denials(team_id);

ALTER TABLE app.teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.teams FORCE ROW LEVEL SECURITY;

ALTER TABLE app.persons ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.persons FORCE ROW LEVEL SECURITY;

ALTER TABLE app.role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.role_assignments FORCE ROW LEVEL SECURITY;

ALTER TABLE app.medical_clearances ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.medical_clearances FORCE ROW LEVEL SECURITY;

ALTER TABLE app.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.audit_log FORCE ROW LEVEL SECURITY;

ALTER TABLE app.access_denials ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.access_denials FORCE ROW LEVEL SECURITY;

-- app.teams: keine explizite Policy (default-deny fuer authenticated).
-- Team-Stammdaten werden ueber service_role/Migration verwaltet.


-- =============================================================================
-- 3. Helper-Funktionen
-- Lesen die simulierten JWT-Claims direkt aus request.jwt.claims:
-- {"sub":"<uuid>","role":"authenticated","app_role":"coach","team_id":"<tid>"}
-- =============================================================================

CREATE OR REPLACE FUNCTION app.auth_person_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
$$;

CREATE OR REPLACE FUNCTION app.auth_team_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'team_id')::uuid;
$$;

CREATE OR REPLACE FUNCTION app.auth_has_role(r app.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'app_role') = r::text;
$$;

CREATE OR REPLACE FUNCTION app.auth_in_team(t uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT app.auth_team_id() = t;
$$;

CREATE OR REPLACE FUNCTION app.auth_is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT app.auth_has_role('coach') OR app.auth_has_role('athletic_coach');
$$;

CREATE OR REPLACE FUNCTION app.auth_is_medical()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT app.auth_has_role('physio') OR app.auth_has_role('doctor');
$$;

REVOKE EXECUTE ON FUNCTION app.auth_person_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_team_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_has_role(app.app_role) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_in_team(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_is_staff() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.auth_is_medical() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.auth_person_id() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION app.auth_team_id() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION app.auth_has_role(app.app_role) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION app.auth_in_team(uuid) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION app.auth_is_staff() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION app.auth_is_medical() TO authenticated, anon, service_role;


-- =============================================================================
-- 4. RLS-Policies
-- =============================================================================

-- persons: SELECT (alle im Team), INSERT/UPDATE (nur admin)
CREATE POLICY persons_select_team ON app.persons
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY persons_insert_admin ON app.persons
  FOR INSERT TO authenticated
  WITH CHECK (app.auth_has_role('admin') AND team_id = app.auth_team_id());

CREATE POLICY persons_update_admin ON app.persons
  FOR UPDATE TO authenticated
  USING (app.auth_has_role('admin') AND team_id = app.auth_team_id())
  WITH CHECK (app.auth_has_role('admin') AND team_id = app.auth_team_id());

-- role_assignments: SELECT (alle im Team), INSERT/UPDATE (nur admin)
CREATE POLICY role_assignments_select_team ON app.role_assignments
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY role_assignments_insert_admin ON app.role_assignments
  FOR INSERT TO authenticated
  WITH CHECK (app.auth_has_role('admin') AND team_id = app.auth_team_id());

CREATE POLICY role_assignments_update_admin ON app.role_assignments
  FOR UPDATE TO authenticated
  USING (app.auth_has_role('admin') AND team_id = app.auth_team_id())
  WITH CHECK (app.auth_has_role('admin') AND team_id = app.auth_team_id());

-- medical_clearances: SELECT (alle im Team), INSERT/UPDATE (nur doctor)
CREATE POLICY medical_clearances_select_team ON app.medical_clearances
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

CREATE POLICY medical_clearances_insert_doctor ON app.medical_clearances
  FOR INSERT TO authenticated
  WITH CHECK (app.auth_has_role('doctor') AND team_id = app.auth_team_id());

CREATE POLICY medical_clearances_update_doctor ON app.medical_clearances
  FOR UPDATE TO authenticated
  USING (app.auth_has_role('doctor') AND team_id = app.auth_team_id())
  WITH CHECK (app.auth_has_role('doctor') AND team_id = app.auth_team_id());

-- audit_log: SELECT (nur admin), INSERT (nur via Trigger/Definer — keine Policy fuer authenticated)
CREATE POLICY audit_log_select_admin ON app.audit_log
  FOR SELECT TO authenticated
  USING (app.auth_has_role('admin') AND team_id = app.auth_team_id());

-- access_denials: SELECT (nur admin), INSERT (nur via Definer — keine Policy fuer authenticated)
CREATE POLICY access_denials_select_admin ON app.access_denials
  FOR SELECT TO authenticated
  USING (app.auth_has_role('admin') AND team_id = app.auth_team_id());


-- =============================================================================
-- 5. Spaltenrechte / Grants
-- =============================================================================

GRANT ALL ON ALL TABLES IN SCHEMA app TO service_role;

GRANT SELECT, INSERT, UPDATE ON app.role_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON app.medical_clearances TO authenticated;
GRANT SELECT ON app.audit_log TO authenticated;
GRANT SELECT ON app.access_denials TO authenticated;

GRANT INSERT, UPDATE ON app.persons TO authenticated;
REVOKE SELECT ON app.persons FROM authenticated;
GRANT SELECT (id, team_id, auth_user_id, display_name, person_position, shirt_number, is_active, created_at, updated_at) ON app.persons TO authenticated;
-- birth_date ist NICHT in der Liste


-- =============================================================================
-- 6. Trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION app.audit_log_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_team_id     uuid;
  v_row_id      uuid;
  v_actor_id    uuid;
  v_actor_role  app.app_role;
BEGIN
  v_actor_id := app.auth_person_id();
  v_actor_role := (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'app_role')::app.app_role;

  IF TG_OP = 'DELETE' THEN
    v_team_id := OLD.team_id;
    v_row_id := OLD.id;
  ELSE
    v_team_id := NEW.team_id;
    v_row_id := NEW.id;
  END IF;

  INSERT INTO app.audit_log (team_id, table_name, row_id, operation, actor_id, actor_role, old_row, new_row)
  VALUES (
    v_team_id,
    TG_TABLE_NAME,
    v_row_id,
    TG_OP,
    v_actor_id,
    v_actor_role,
    CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.audit_log_trigger() FROM PUBLIC;

CREATE TRIGGER medical_clearances_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.medical_clearances
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();

CREATE TRIGGER persons_audit
  AFTER INSERT OR UPDATE OR DELETE ON app.persons
  FOR EACH ROW EXECUTE FUNCTION app.audit_log_trigger();
