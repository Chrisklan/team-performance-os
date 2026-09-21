-- =============================================================================
-- 09_rpcs.pgtap.sql — Tests für alle 11 RPCs aus 09_rpcs.sql
-- Verwendet pgtap 1.3.x (ohne _ensure_schema)
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;

SELECT no_plan();

-- =============================================================================
-- TEST-DB SETUP
-- =============================================================================

INSERT INTO app.teams (id, name, timezone) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Test Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id) VALUES
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Admin User', 'admin', '22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'Coach User', 'coach', '33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'Physio User', 'physio', '44444444-4444-4444-4444-444444444444'),
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', 'Doctor User', 'doctor', '55555555-5555-5555-5555-555555555555'),
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111', 'Player User', 'player', '66666666-6666-6666-6666-666666666666');

INSERT INTO app.role_assignments (team_id, person_id, role) VALUES
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'admin'),
  ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', 'coach'),
  ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444', 'physio'),
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'doctor'),
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'player');

INSERT INTO app.daily_checkins (id, team_id, person_id, date, body_map) VALUES
  ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', '{"region": "knee", "value": 3}'::jsonb);

INSERT INTO app.readiness_scores (id, team_id, person_id, date, score_total, band, factors) VALUES
  ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 85.5, 'high', '{"sleep": 8.0}'::jsonb);

INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 15.5, 'unreviewed');

INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'limited', 'max 60 min', '2026-09-01', '55555555-5555-5555-5555-555555555555', 'doctor');


-- =============================================================================
-- JWT HELPER
-- =============================================================================

CREATE OR REPLACE FUNCTION app._test_set_jwt(jsonb) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', $1::text, true);
$$;


-- =============================================================================
-- POSITIVE TESTS (rpc_get_my_roles als Admin)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_admin_denials('2026-09-01', '2026-09-30')$$, 'rpc_admin_denials als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_shred_person('66666666-6666-6666-6666-666666666666')$$, 'rpc_shred_person als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_export_my_data()$$, 'rpc_export_my_data als Admin');

-- Zuruecksetzen (nach shred sind Daten weg, also neu setzen).
-- Seit AP-39b raeumt rpc_shred_person v2 alle Speicherorte der Person, nicht mehr
-- nur app.persons. Die Fixtures fuer Check-In, Score und Lastabweichung kommen
-- deshalb hier ebenfalls zurueck.
SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id) VALUES
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111', 'Player User', 'player', '66666666-6666-6666-6666-666666666666')
ON CONFLICT (id) DO UPDATE SET is_active = true, display_name = 'Player User', auth_user_id = '66666666-6666-6666-6666-666666666666', birth_date = NULL, updated_at = now();

INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'limited', 'max 60 min', '2026-09-01', '55555555-5555-5555-5555-555555555555', 'doctor')
ON CONFLICT DO NOTHING;

INSERT INTO app.daily_checkins (id, team_id, person_id, date, body_map) VALUES
  ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', '{"region": "knee", "value": 3}'::jsonb)
ON CONFLICT DO NOTHING;

INSERT INTO app.readiness_scores (id, team_id, person_id, date, score_total, band, factors) VALUES
  ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 85.5, 'high', '{"sleep": 8.0}'::jsonb)
ON CONFLICT DO NOTHING;

INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 15.5, 'unreviewed')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- POSITIVE TESTS (Coach)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Coach');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Coach');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Coach');

-- =============================================================================
-- POSITIVE TESTS (Physio)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_propose_clearance('66666666-6666-6666-6666-666666666666', 'limited', 'nur individuell')$$, 'rpc_propose_clearance als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'release')$$, 'rpc_release_deviation als Physio');

-- =============================================================================
-- POSITIVE TESTS (Doctor)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated","app_role":"doctor","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', 'voll belastbar', '2026-09-03', NULL)$$, 'rpc_set_clearance als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'dismiss')$$, 'rpc_release_deviation als Doctor');

-- =============================================================================
-- POSITIVE TESTS (Player)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_access_log('2026-09-01', '2026-09-30')$$, 'rpc_get_my_access_log als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_export_my_data()$$, 'rpc_export_my_data als Player');


-- =============================================================================
-- NEGATIVE TESTS (FORBIDDEN 42501)
-- =============================================================================

-- Coach darf body_map nicht
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: daily_checkins.body_map', 'rpc_check_ins_medical blockt Coach');

-- Coach darf readiness_full nicht
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: readiness_scores.score_total', 'rpc_readiness_full blockt Coach');

-- Coach darf Clearance nicht setzen
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL, '2026-09-03', NULL)$$, '42501', 'FORBIDDEN: medical_clearances.set (only doctor)', 'rpc_set_clearance blockt Coach');

-- Physio darf nicht setzen
SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL, '2026-09-03', NULL)$$, '42501', 'FORBIDDEN: medical_clearances.set (only doctor)', 'rpc_set_clearance blockt Physio');

-- Player darf Liste nicht sehen
SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_list_team_members()$$, '42501', 'FORBIDDEN: persons.list', 'rpc_list_team_members blockt Player');

-- Player darf nicht freigeben
SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'release')$$, '42501', 'FORBIDDEN: load_deviations.release', 'rpc_release_deviation blockt Player');

-- Coach darf nicht shredden
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_shred_person('66666666-6666-6666-6666-666666666666')$$, '42501', 'FORBIDDEN: persons.shred (only admin)', 'rpc_shred_person blockt Coach');

-- Coach darf Admin-Denials nicht sehen
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_admin_denials('2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: access_denials.admin', 'rpc_admin_denials blockt Coach');


-- =============================================================================
-- AUDIT LOG TEST
-- =============================================================================

SELECT ok((SELECT count(*) > 0 FROM app.audit_log), 'audit_log hat Eintraege');
SELECT ok((SELECT count(*) > 0 FROM app.access_log), 'access_log hat Eintraege');


-- =============================================================================
-- VOCABULARY CHECK (kein verbotenes Vokabular)
-- =============================================================================

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'app' AND (p.proname LIKE '%tenant%' OR p.proname LIKE '%player_id%')),
  'Keine verbotenen Funktionsnamen'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'app' AND c.relkind = 'r' AND (c.relname LIKE '%tenant%' OR c.relname IN ('players'))),
  'Keine verbotenen Tabellennamen'
);


SELECT finish();
