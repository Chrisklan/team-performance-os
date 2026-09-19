-- =============================================================================
-- 20260919000017_auth_claims_hook.sql — AP-29 Claims-Hook (ADR-015 A+ Stufe 2)
--
-- 1. DB-Regel: eine aktive Rolle pro Person (Exclusion Constraint, btree_gist).
-- 2. DB-Waechter Stufe 2 in app.auth_team_id() und app.auth_has_role():
--    Claims gelten nur, wenn Person gebunden und aktiv ist und die Rolle aus
--    dem Claim jetzt in app.role_assignments gilt. auth_has_role() liefert nie
--    NULL.
-- 3. app.log_denial(): ohne bestaetigtes Team kein INSERT (sonst 23502 statt
--    FORBIDDEN).
-- 4. Custom Access Token Hook app.custom_access_token_hook(jsonb) mit Rechten
--    nur fuer supabase_auth_admin.
--
-- Quelle im Repo: backend/08_reconciling.sql (1, 2), backend/09_rpcs.sql (3),
-- backend/10_auth_hook.sql (4). Tests: backend/10_auth_hook.pgtap.sql.
-- Schreibt keine Daten. Aktiviert den Hook NICHT, das passiert in der
-- Auth-Konfiguration (Dashboard oder Management API).
-- Atomar: Die Supabase-CLI spielt die Datei in einer Transaktion ein.
-- =============================================================================


-- =============================================================================
-- 1. Eine aktive Rolle pro Person
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'app.role_assignments'::regclass
      AND conname = 'role_assignments_one_active_role'
  ) THEN
    ALTER TABLE app.role_assignments
      ADD CONSTRAINT role_assignments_one_active_role EXCLUDE USING gist (
        person_id WITH =,
        tstzrange(valid_from, valid_to) WITH &&
      );
  END IF;
END $$;


-- =============================================================================
-- 2. DB-Waechter Stufe 2
-- =============================================================================

-- DB-Waechter Stufe 2 (ADR-015): Die Claims app_role und team_id gelten nur,
-- wenn die DB sie in diesem Moment bestaetigt: Person ueber JWT sub gebunden
-- und aktiv, team_id der Person = Claim, Rolle aus dem Claim in
-- app.role_assignments jetzt gueltig. Shredding, Deaktivierung und
-- Rollenentzug sperren damit sofort, auch mit einem noch gueltigen Token.
-- auth_team_id() IS NOT NULL heisst: Claims bestaetigt.
CREATE OR REPLACE FUNCTION app.auth_team_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT pe.team_id
  FROM (SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb AS j) c
  JOIN app.persons pe
    ON pe.id = app.auth_person_id()
   AND pe.is_active
   AND pe.team_id::text = c.j ->> 'team_id'
  JOIN app.role_assignments ra
    ON ra.person_id = pe.id
   AND ra.team_id = pe.team_id
   AND ra.role::text = c.j ->> 'app_role'
   AND ra.valid_from <= now()
   AND (ra.valid_to IS NULL OR ra.valid_to > now())
  LIMIT 1;
$$;

-- Nie NULL: ohne bestaetigte Claims false, damit "IF NOT app.auth_has_role()"
-- in den RPCs sicher FORBIDDEN wirft.
CREATE OR REPLACE FUNCTION app.auth_has_role(r app.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
  SELECT coalesce(
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'app_role') = r::text
      AND app.auth_team_id() IS NOT NULL,
    false
  );
$$;


-- =============================================================================
-- 3. app.log_denial()
-- =============================================================================

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


-- =============================================================================
-- 4. Custom Access Token Hook
-- =============================================================================

CREATE OR REPLACE FUNCTION app.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_user_id    uuid;
  v_person_id  uuid;
  v_team_id    uuid;
  v_roles      text[];
  v_claims     jsonb;
BEGIN
  BEGIN
    v_user_id := (event ->> 'user_id')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_user_id := NULL;
  END;

  IF v_user_id IS NOT NULL THEN
    SELECT pe.id, pe.team_id
    INTO v_person_id, v_team_id
    FROM app.persons pe
    WHERE pe.auth_user_id = v_user_id
      AND pe.is_active;
  END IF;

  IF v_person_id IS NULL THEN
    RETURN jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Kein aktives Profil für diesen Login. Bitte Admin informieren.'
    ));
  END IF;

  SELECT array_agg(ra.role::text ORDER BY ra.role)
  INTO v_roles
  FROM app.role_assignments ra
  WHERE ra.person_id = v_person_id
    AND ra.team_id = v_team_id
    AND ra.valid_from <= now()
    AND (ra.valid_to IS NULL OR ra.valid_to > now());

  IF coalesce(cardinality(v_roles), 0) = 0 THEN
    RETURN jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Keine aktive Rolle für diesen Login. Bitte Admin informieren.'
    ));
  END IF;

  -- ADR-009 Punkt 4: keine Rolle gewinnt, kein Login mit geratener Rolle.
  IF cardinality(v_roles) > 1 THEN
    RETURN jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Rolle nicht eindeutig. Bitte Admin informieren.'
    ));
  END IF;

  -- Pflicht-Claims bleiben unveraendert. Verbotene Claims werden entfernt,
  -- falls sie je von anderer Stelle kaemen (Legacy app.tenant() liest tenant_id).
  v_claims := coalesce(event -> 'claims', '{}'::jsonb)
              - 'tenant_id' - 'player_id' - 'person_id';
  v_claims := v_claims || jsonb_build_object(
                'app_role', v_roles[1],
                'team_id',  v_team_id
              );

  RETURN jsonb_set(event, '{claims}', v_claims);
END;
$$;

COMMENT ON FUNCTION app.custom_access_token_hook(jsonb) IS
  'Supabase Custom Access Token Hook (ADR-015): sets top-level app_role and team_id from app.persons/app.role_assignments. 403 if no active bound person, no active role or more than one active role. Never writes tenant_id.';


-- =============================================================================
-- Rechte
-- =============================================================================

GRANT USAGE ON SCHEMA app TO supabase_auth_admin;

REVOKE EXECUTE ON FUNCTION app.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.custom_access_token_hook(jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION app.custom_access_token_hook(jsonb) TO supabase_auth_admin;

-- Nur die Spalten, die der Hook liest. birth_date und display_name nicht.
GRANT SELECT (id, team_id, auth_user_id, is_active) ON app.persons TO supabase_auth_admin;
GRANT SELECT (person_id, team_id, role, valid_from, valid_to) ON app.role_assignments TO supabase_auth_admin;

DROP POLICY IF EXISTS persons_select_auth_hook ON app.persons;
CREATE POLICY persons_select_auth_hook ON app.persons
  FOR SELECT TO supabase_auth_admin
  USING (true);

DROP POLICY IF EXISTS role_assignments_select_auth_hook ON app.role_assignments;
CREATE POLICY role_assignments_select_auth_hook ON app.role_assignments
  FOR SELECT TO supabase_auth_admin
  USING (true);
