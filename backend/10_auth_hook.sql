-- =============================================================================
-- 10_auth_hook.sql — Custom Access Token Hook (AP-29, ADR-015 A+ Stufe 2)
--
-- Supabase Auth ruft app.custom_access_token_hook(event) vor jeder Token-
-- Ausgabe auf (Login und Refresh) und schreibt top-level:
--   app_role  (Wert aus app.app_role)
--   team_id   (uuid)
-- Sonst nichts. Nie tenant_id, player_id, person_id, Namen oder
-- Gesundheitsdaten (ADR-001, ADR-015 Festlegungen).
--
-- Quelle: app.persons (auth_user_id = event.user_id, is_active) und genau
-- eine jetzt gueltige Zeile in app.role_assignments.
-- Keine Person, inaktiv, keine Rolle, mehr als eine Rolle: 403, kein Token.
-- Beim Refresh endet damit die Session nach Shredding oder Rollenentzug.
--
-- Laeuft als supabase_auth_admin (SECURITY INVOKER, wie die Supabase-Doku
-- verlangt). Rechte nur fuer diese Rolle: USAGE auf app, EXECUTE auf den
-- Hook, SELECT auf die noetigen Spalten und je eine SELECT-Policy auf
-- app.persons und app.role_assignments (beide FORCE RLS).
--
-- Voraussetzung: 08_reconciling.sql. Lokal muss die Rolle
-- supabase_auth_admin existieren (backend/tests/local_supabase_roles.sql).
-- Idempotent.
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
