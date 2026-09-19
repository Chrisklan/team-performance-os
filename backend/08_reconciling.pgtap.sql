-- =============================================================================
-- 08_reconciling.pgtap.sql — pgTAP Test-Suite für Reconciling-Migration (AP13b-Schritt-2)
-- =============================================================================

BEGIN;
SELECT plan(41);

-- =============================================================================
-- SETUP: Testdaten als Superuser
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';

INSERT INTO app.teams (id, name, timezone) VALUES ('22222222-2222-2222-2222-222222222222'::uuid, 'Test Team', 'Europe/Berlin');
INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES ('33333333-3333-3333-3333-333333333333'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Test Person', '11111111-1111-1111-1111-111111111111'::uuid);
INSERT INTO app.persons (id, team_id, display_name) VALUES ('33333333-3333-3333-3333-333333333334'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Test Person 2');
INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES ('44444444-4444-4444-4444-444444444444'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Doctor Person', '44444444-4444-4444-4444-444444444444'::uuid);
INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES ('44444444-4444-4444-4444-444444444445'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Physio Person', '44444444-4444-4444-4444-444444444445'::uuid);
INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-444444444446'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333333'::uuid, 'player');
INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-444444444447'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '44444444-4444-4444-4444-444444444444'::uuid, 'doctor');
INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-444444444448'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '44444444-4444-4444-4444-444444444445'::uuid, 'physio');
-- ADR-015 Stufe 2: Claims gelten nur, wenn role_assignments sie bestaetigt.
-- Admin- und Coach-Claims brauchen deshalb eigene Personen mit dieser Rolle.
INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Admin Person', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid);
INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Coach Person', 'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid);
INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-44444444444a'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'admin');
INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-44444444444c'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid, 'coach');


-- =============================================================================
-- 1. HELPER: Funktionen existieren
-- =============================================================================

SELECT has_function('app', 'auth_person_id', 'app.auth_person_id() exists');
SELECT has_function('app', 'auth_team_id', 'app.auth_team_id() exists');
SELECT has_function('app', 'auth_has_role', 'app.auth_has_role(app.app_role) exists');
SELECT has_function('app', 'auth_in_team', 'app.auth_in_team(uuid) exists');
SELECT has_function('app', 'auth_is_staff', 'app.auth_is_staff() exists');
SELECT has_function('app', 'auth_is_medical', 'app.auth_is_medical() exists');


-- =============================================================================
-- 2. HELPER: Rückgabewerte als authenticated
-- =============================================================================

SET ROLE authenticated;

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';

SELECT is(app.auth_person_id(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'auth_person_id() resolves persons.id via auth_user_id = JWT sub');
SELECT is(app.auth_team_id(), '22222222-2222-2222-2222-222222222222'::uuid, 'auth_team_id() returns team_id from JWT, confirmed by DB');
SELECT is(app.auth_has_role('admin'), true, 'auth_has_role(''admin'') = true when app_role=admin');
SELECT is(app.auth_has_role('coach'), false, 'auth_has_role(''coach'') = false when app_role=admin');
SELECT is(app.auth_in_team('22222222-2222-2222-2222-222222222222'::uuid), true, 'auth_in_team() returns true for own team');
SELECT is(app.auth_in_team('99999999-9999-9999-9999-999999999999'::uuid), false, 'auth_in_team() returns false for other team');


-- =============================================================================
-- 3. HELPER: auth_is_staff / auth_is_medical als Coach
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';

SELECT is(app.auth_is_staff(), true, 'auth_is_staff() = true for coach');
SELECT is(app.auth_is_medical(), false, 'auth_is_medical() = false for coach');


-- =============================================================================
-- 4. RLS-POLICIES: persons
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.persons)::int, 6, 'admin sees 6 persons in team');

SELECT lives_ok(
  $$INSERT INTO app.persons (id, team_id, display_name) VALUES ('33333333-3333-3333-3333-333333333335'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Admin Insert')$$,
  'admin can insert person'
);

SELECT lives_ok(
  $$UPDATE app.persons SET display_name = 'Admin Updated' WHERE id = '33333333-3333-3333-3333-333333333335'::uuid$$,
  'admin can update person'
);

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.persons)::int, 7, 'coach sees 7 persons in team');

SELECT throws_ok(
  $$INSERT INTO app.persons (team_id, display_name) VALUES ('22222222-2222-2222-2222-222222222222'::uuid, 'Coach Insert')$$,
  42501,
  NULL,
  'coach cannot insert person'
);


-- =============================================================================
-- 5. RLS-POLICIES: role_assignments
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.role_assignments)::int, 5, 'admin sees 5 role_assignments initially');

SELECT lives_ok(
  $$INSERT INTO app.role_assignments (id, team_id, person_id, role) VALUES ('44444444-4444-4444-4444-444444444449'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333334'::uuid, 'coach')$$,
  'admin can insert role_assignment'
);

SELECT lives_ok(
  $$UPDATE app.role_assignments SET role = 'athletic_coach' WHERE id = '44444444-4444-4444-4444-444444444449'::uuid$$,
  'admin can update role_assignment'
);

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.role_assignments)::int, 6, 'coach sees 6 role_assignments');

SELECT throws_ok(
  $$INSERT INTO app.role_assignments (team_id, person_id, role) VALUES ('22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333335'::uuid, 'player')$$,
  42501,
  NULL,
  'coach cannot insert role_assignment'
);


-- =============================================================================
-- 6. RLS-POLICIES: medical_clearances
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"doctor","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.medical_clearances)::int, 0, 'doctor sees 0 medical_clearances initially');

SELECT lives_ok(
  $$INSERT INTO app.medical_clearances (id, team_id, person_id, status, set_by, set_by_role) VALUES ('55555555-5555-5555-5555-555555555555'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333333'::uuid, 'full', '44444444-4444-4444-4444-444444444444'::uuid, 'doctor')$$,
  'doctor can insert medical_clearance'
);

SELECT lives_ok(
  $$UPDATE app.medical_clearances SET status = 'limited' WHERE id = '55555555-5555-5555-5555-555555555555'::uuid$$,
  'doctor can update medical_clearance'
);

SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444445","role":"authenticated","app_role":"physio","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.medical_clearances)::int, 1, 'physio sees 1 medical_clearance in team');

SELECT throws_ok(
  $$INSERT INTO app.medical_clearances (team_id, person_id, status, set_by, set_by_role) VALUES ('22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333333'::uuid, 'full', '44444444-4444-4444-4444-444444444445'::uuid, 'physio')$$,
  42501,
  NULL,
  'physio cannot insert medical_clearance'
);

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.medical_clearances)::int, 1, 'coach sees 1 medical_clearance in team');


-- =============================================================================
-- 7. RLS-POLICIES: audit_log (admin-only)
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT ok((SELECT count(*) FROM app.audit_log) > 0, 'admin can read audit_log (entries from trigger)');

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.audit_log)::int, 0, 'coach cannot read audit_log');


-- =============================================================================
-- 8. RLS-POLICIES: access_denials (admin-only)
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.access_denials)::int, 0, 'admin sees 0 access_denials initially');

SET LOCAL request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","role":"authenticated","app_role":"coach","team_id":"22222222-2222-2222-2222-222222222222"}';
SELECT is((SELECT count(*) FROM app.access_denials)::int, 0, 'coach cannot read access_denials');


-- =============================================================================
-- 9. SPALTENRECHTE: persons.birth_date
-- =============================================================================

SELECT throws_ok(
  $$SELECT birth_date FROM app.persons LIMIT 1$$,
  42501,
  'permission denied for table persons',
  'coach cannot select birth_date (42501)'
);

SELECT lives_ok(
  $$SELECT id, display_name, person_position, shirt_number FROM app.persons LIMIT 1$$,
  'coach can select allowed columns'
);


-- =============================================================================
-- 10. TRIGGER: audit_log bei medical_clearances INSERT
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"doctor","team_id":"22222222-2222-2222-2222-222222222222"}';

INSERT INTO app.medical_clearances (id, team_id, person_id, status, set_by, set_by_role) VALUES ('55555555-5555-5555-5555-555555555556'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '33333333-3333-3333-3333-333333333333'::uuid, 'individual', '44444444-4444-4444-4444-444444444444'::uuid, 'doctor');

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';

SELECT is(
  (SELECT count(*) FROM app.audit_log WHERE table_name = 'medical_clearances' AND row_id = '55555555-5555-5555-5555-555555555556'::uuid AND operation = 'INSERT')::int,
  1,
  'INSERT on medical_clearances creates audit_log entry'
);


-- =============================================================================
-- 11. TRIGGER: audit_log bei medical_clearances UPDATE
-- =============================================================================

SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"doctor","team_id":"22222222-2222-2222-2222-222222222222"}';

UPDATE app.medical_clearances SET status = 'blocked', load_note = 'No training' WHERE id = '55555555-5555-5555-5555-555555555556'::uuid;

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';

SELECT is(
  (SELECT count(*) FROM app.audit_log WHERE table_name = 'medical_clearances' AND row_id = '55555555-5555-5555-5555-555555555556'::uuid AND operation = 'UPDATE')::int,
  1,
  'UPDATE on medical_clearances creates audit_log entry'
);

SELECT ok(
  (SELECT old_row IS NOT NULL AND new_row IS NOT NULL FROM app.audit_log WHERE table_name = 'medical_clearances' AND operation = 'UPDATE' AND row_id = '55555555-5555-5555-5555-555555555556'::uuid LIMIT 1),
  'audit_log UPDATE entry has old_row and new_row as jsonb'
);


-- =============================================================================
-- 12. TRIGGER: audit_log bei medical_clearances DELETE (als Superuser)
-- =============================================================================

SET ROLE christopherklan;

DELETE FROM app.medical_clearances WHERE id = '55555555-5555-5555-5555-555555555556'::uuid;

SELECT is(
  (SELECT count(*) FROM app.audit_log WHERE table_name = 'medical_clearances' AND row_id = '55555555-5555-5555-5555-555555555556'::uuid AND operation = 'DELETE')::int,
  1,
  'DELETE on medical_clearances creates audit_log entry'
);


-- =============================================================================
-- 13. TRIGGER: audit_log bei persons INSERT
-- =============================================================================

SET ROLE authenticated;

SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_role":"admin","team_id":"22222222-2222-2222-2222-222222222222"}';

INSERT INTO app.persons (id, team_id, display_name) VALUES ('33333333-3333-3333-3333-333333333336'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 'Trigger Test Person');

SELECT is(
  (SELECT count(*) FROM app.audit_log WHERE table_name = 'persons' AND row_id = '33333333-3333-3333-3333-333333333336'::uuid AND operation = 'INSERT')::int,
  1,
  'INSERT on persons creates audit_log entry'
);


-- =============================================================================
-- CLEANUP
-- =============================================================================

SET ROLE christopherklan;

SELECT * FROM finish();
ROLLBACK;
