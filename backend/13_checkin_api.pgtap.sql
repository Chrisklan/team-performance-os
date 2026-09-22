-- =============================================================================
-- 13_checkin_api.pgtap.sql — public.rpc_submit_checkin (AP-34)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, 11_checkin_submit.sql, 12_trainer_api.sql, 13_checkin_api.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(13);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('13131313-1313-1313-1313-131313131313', 'Tuer Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('d1000000-0000-0000-0000-000000000002', '13131313-1313-1313-1313-131313131313', 'Coach',   'd2000000-0000-0000-0000-000000000002', NULL),
  ('d1000000-0000-0000-0000-000000000003', '13131313-1313-1313-1313-131313131313', 'Spieler', 'd2000000-0000-0000-0000-000000000003', 9);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('13131313-1313-1313-1313-131313131313', 'd1000000-0000-0000-0000-000000000002', 'coach',  now() - interval '1 day'),
  ('13131313-1313-1313-1313-131313131313', 'd1000000-0000-0000-0000-000000000003', 'player', now() - interval '1 day');

CREATE FUNCTION app._t_jwt13(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '13131313-1313-1313-1313-131313131313')::text,
    true);
$$;

SELECT has_function('public', 'rpc_submit_checkin',
  ARRAY['date','numeric','integer','integer','integer','integer','integer','integer','integer','jsonb'],
  'Tuer existiert');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'rpc_submit_checkin' AND pronamespace = 'public'::regnamespace),
  false, 'Tuer ist SECURITY INVOKER');
SELECT ok(NOT has_function_privilege('anon',
  'public.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)', 'EXECUTE'),
  'anon darf die Tuer nicht aufrufen');
SELECT ok(has_function_privilege('authenticated',
  'public.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)', 'EXECUTE'),
  'authenticated darf die Tuer aufrufen');

-- Spieler: Check-In ueber die Tuer
SET ROLE authenticated;
SELECT app._t_jwt13('d2000000-0000-0000-0000-000000000003', 'player');
SELECT lives_ok(
  $$SELECT public.rpc_submit_checkin(current_date, 450, 8, 7, 6, 3, 8, 7, 8,
      '[{"region":"knie_l","pain":4,"art":"muskulaer"},{"region":"lws_kreuz","pain":2}]'::jsonb)$$,
  'Spieler: Check-In ueber die Tuer wird gespeichert');
RESET ROLE;

SELECT is((SELECT count(*)::int FROM app.daily_checkins
           WHERE person_id = 'd1000000-0000-0000-0000-000000000003' AND date = current_date),
  1, 'Zeile liegt in app.daily_checkins');
SELECT is((SELECT sleep_duration_min FROM app.daily_checkins
           WHERE person_id = 'd1000000-0000-0000-0000-000000000003'),
  450::numeric, 'Werte kommen unveraendert an (Schlaf in Minuten)');
SELECT is((SELECT pain_max::int FROM app.daily_checkins
           WHERE person_id = 'd1000000-0000-0000-0000-000000000003'),
  4, 'pain_max aus der Body Map berechnet');
SELECT is((SELECT band::text FROM app.readiness_scores
           WHERE person_id = 'd1000000-0000-0000-0000-000000000003' AND date = current_date),
  'high', 'Score im selben Aufruf geschrieben');

-- Trainer: FORBIDDEN
SET ROLE authenticated;
SELECT app._t_jwt13('d2000000-0000-0000-0000-000000000002', 'coach');
SELECT is((SELECT public.rpc_submit_checkin(current_date, 450, 8, 7, 6, 3, 8, 7, 8, NULL)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.submit', 'details', NULL, 'hint', NULL),
  'Trainer darf ueber die Tuer keinen Check-In abgeben');

-- Gefaelschter player-Claim ohne passende Rolle in der DB: FORBIDDEN (Stufe 2)
SELECT app._t_jwt13('d2000000-0000-0000-0000-000000000002', 'player');
SELECT is((SELECT public.rpc_submit_checkin(current_date, 450, 8, 7, 6, 3, 8, 7, 8, NULL)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.submit', 'details', NULL, 'hint', NULL),
  'Gefaelschter player-Claim: FORBIDDEN');

-- Datumsfenster bleibt in der RPC
SELECT app._t_jwt13('d2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT public.rpc_submit_checkin(current_date + 1, 450, 8, 7, 6, 3, 8, 7, 8, NULL)$$,
  '42501', 'FORBIDDEN: daily_checkins.date', 'Datum in der Zukunft: FORBIDDEN');
RESET ROLE;

-- anon: an der Tuer abgewiesen
SET ROLE anon;
SELECT throws_ok($$SELECT public.rpc_submit_checkin(current_date, 450, 8, 7, 6, 3, 8, 7, 8, NULL)$$,
  '42501', NULL, 'anon: permission denied');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
