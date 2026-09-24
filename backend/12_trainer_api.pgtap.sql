-- =============================================================================
-- 12_trainer_api.pgtap.sql — public.rpc_trainer_morning_ops (AP-30)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, 11_checkin_submit.sql, 12_trainer_api.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(10);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('12121212-1212-1212-1212-121212121212', 'Wrapper Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('c1000000-0000-0000-0000-000000000002', '12121212-1212-1212-1212-121212121212', 'Coach',   'c2000000-0000-0000-0000-000000000002', NULL),
  ('c1000000-0000-0000-0000-000000000003', '12121212-1212-1212-1212-121212121212', 'Spieler', 'c2000000-0000-0000-0000-000000000003', 7);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('12121212-1212-1212-1212-121212121212', 'c1000000-0000-0000-0000-000000000002', 'coach',  now() - interval '1 day'),
  ('12121212-1212-1212-1212-121212121212', 'c1000000-0000-0000-0000-000000000003', 'player', now() - interval '1 day');

CREATE FUNCTION app._t_jwt12(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '12121212-1212-1212-1212-121212121212')::text,
    true);
$$;

SELECT has_function('public', 'rpc_trainer_morning_ops', ARRAY[]::text[], 'Tuer existiert');
SELECT is((SELECT prosecdef FROM pg_proc WHERE oid = 'public.rpc_trainer_morning_ops()'::regprocedure),
  false, 'Tuer ist SECURITY INVOKER');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_trainer_morning_ops()', 'EXECUTE'),
  'anon darf die Tuer nicht aufrufen');
SELECT ok(has_function_privilege('authenticated', 'public.rpc_trainer_morning_ops()', 'EXECUTE'),
  'authenticated darf die Tuer aufrufen');

-- Trainer: bekommt seinen Kader
SET ROLE authenticated;
SELECT app._t_jwt12('c2000000-0000-0000-0000-000000000002', 'coach');
SELECT is((public.rpc_trainer_morning_ops() ->> 'kaderName'), 'Wrapper Team', 'Trainer: Kadername aus seinem Team');
-- Bridge Punkt 67 (2026-09-24): nur die Spielerin zaehlt, der Coach dieses
-- Fixtures traegt keine Rolle player.
SELECT is(jsonb_array_length(public.rpc_trainer_morning_ops() -> 'members'), 1, 'Trainer: 1 Mitglied (nur die Spielerin, Punkt 67)');
SELECT is(public.rpc_trainer_morning_ops(), app.rpc_morning_ops(), 'Tuer liefert dasselbe Payload wie app.rpc_morning_ops');

-- Spieler: FORBIDDEN
SELECT app._t_jwt12('c2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT public.rpc_trainer_morning_ops()$$, '42501', 'FORBIDDEN', 'Spieler: FORBIDDEN');

-- Trainer-Claim ohne passende Rolle in der DB: FORBIDDEN (Stufe 2)
SELECT app._t_jwt12('c2000000-0000-0000-0000-000000000003', 'coach');
SELECT throws_ok($$SELECT public.rpc_trainer_morning_ops()$$, '42501', 'FORBIDDEN', 'Gefaelschter coach-Claim: FORBIDDEN');
RESET ROLE;

-- anon: an der Tuer abgewiesen
SET ROLE anon;
SELECT throws_ok($$SELECT public.rpc_trainer_morning_ops()$$, '42501', NULL, 'anon: permission denied');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
