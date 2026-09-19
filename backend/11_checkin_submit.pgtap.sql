-- =============================================================================
-- 11_checkin_submit.pgtap.sql — app.rpc_submit_checkin (AP-33, ADR-016)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, 11_checkin_submit.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(20);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Checkin Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('b1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Admin',   'b2000000-0000-0000-0000-000000000001', NULL),
  ('b1000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Coach',   'b2000000-0000-0000-0000-000000000002', NULL),
  ('b1000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Spieler', 'b2000000-0000-0000-0000-000000000003', 9);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('11111111-1111-1111-1111-111111111111', 'b1000000-0000-0000-0000-000000000001', 'admin',  now() - interval '1 day'),
  ('11111111-1111-1111-1111-111111111111', 'b1000000-0000-0000-0000-000000000002', 'coach',  now() - interval '1 day'),
  ('11111111-1111-1111-1111-111111111111', 'b1000000-0000-0000-0000-000000000003', 'player', now() - interval '1 day');

CREATE FUNCTION app._t_jwt(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '11111111-1111-1111-1111-111111111111')::text,
    true);
$$;

SELECT has_function('app', 'rpc_submit_checkin', 'app.rpc_submit_checkin existiert');

SET ROLE authenticated;

-- Spieler: Check-In von heute
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, 480, 8, 7, 6, 3, 8, 7, 8,
      '[{"region":"knee_left","pain":4,"art":"muskulaer"},{"region":"back","pain":2}]'::jsonb)$$,
  'Spieler: Check-In von heute wird gespeichert');

RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.daily_checkins WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  1, 'Zeile liegt in app.daily_checkins');
SELECT is((SELECT team_id FROM app.daily_checkins WHERE person_id = 'b1000000-0000-0000-0000-000000000003'),
  '11111111-1111-1111-1111-111111111111'::uuid, 'team_id kommt aus dem Waechter, nicht aus Parametern');
SELECT is((SELECT pain_max::int FROM app.daily_checkins WHERE person_id = 'b1000000-0000-0000-0000-000000000003'),
  4, 'pain_max aus der Body Map berechnet');
SELECT is((SELECT band::text FROM app.readiness_scores WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  'high', 'Score im selben Aufruf geschrieben (Band high)');

-- Zweiter Check-In am selben Tag ersetzt
SET ROLE authenticated;
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT lives_ok($$SELECT app.rpc_submit_checkin(current_date, 420, 3, 3, 3, 9, 3, 3, 3, NULL)$$,
  'Spieler: zweiter Check-In am selben Tag ersetzt den ersten');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.daily_checkins WHERE person_id = 'b1000000-0000-0000-0000-000000000003'),
  1, 'Idempotent: weiter genau eine Zeile je Tag');
SELECT is((SELECT band::text FROM app.readiness_scores WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  'low', 'Score wird beim Ersetzen neu berechnet');

-- Trainer sieht den Check-In im Dashboard
SET ROLE authenticated;
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (SELECT (m -> 'hasCheckIn')::boolean FROM jsonb_array_elements(app.rpc_morning_ops() -> 'members') m
   WHERE m #>> '{player,id}' = 'b1000000-0000-0000-0000-000000000003'),
  true, 'Trainer: rpc_morning_ops zeigt hasCheckIn = true');
SELECT throws_ok($$SELECT body_map FROM app.daily_checkins LIMIT 1$$, '42501', NULL,
  'Trainer: body_map bleibt gesperrt');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date, 480, 8, 8, 8, 2, 8, 8, 8, NULL)$$,
  '42501', 'FORBIDDEN: daily_checkins.submit', 'Trainer darf keinen Check-In abgeben');

-- Datum
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date + 1)$$,
  '42501', 'FORBIDDEN: daily_checkins.date', 'Datum in der Zukunft abgelehnt');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date - 3)$$,
  '42501', 'FORBIDDEN: daily_checkins.date', 'Datum aelter als 2 Tage abgelehnt');
SELECT lives_ok($$SELECT app.rpc_submit_checkin(current_date - 2, 450, 6, 6, 6, 4, 6, 6, 6, NULL)$$,
  'Offline-Nachtrag 2 Tage zurueck erlaubt');

-- Body Map
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '{"region":"knee"}'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map', 'Body Map muss ein Array sein');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"region":"knee","pain":11}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map', 'Schmerzwert ueber 10 abgelehnt');

-- Ohne Claims
SELECT set_config('request.jwt.claims', '', true);
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date)$$,
  '42501', 'FORBIDDEN: daily_checkins.submit', 'Ohne Claims FORBIDDEN');

-- Nach Shredding sofort gesperrt
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000001', 'admin');
SELECT app.rpc_shred_person('b1000000-0000-0000-0000-000000000003');
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date)$$,
  '42501', 'FORBIDDEN: daily_checkins.submit', 'Nach Shredding: Check-In sofort FORBIDDEN');
RESET ROLE;

SET ROLE anon;
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date)$$, '42501', NULL, 'anon darf die RPC nicht ausfuehren');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
