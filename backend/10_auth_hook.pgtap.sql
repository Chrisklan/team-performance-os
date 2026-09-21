-- =============================================================================
-- 10_auth_hook.pgtap.sql — Custom Access Token Hook und DB-Waechter Stufe 2
-- (AP-29, ADR-015 Abschnitt 6, Tests 1 bis 7 plus DB-Regel und Wiederholungs-
-- faelle fuer Shredding, Deaktivierung und Rollenentzug).
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, lokal backend/tests/local_supabase_roles.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(38);

-- =============================================================================
-- SETUP (als Superuser)
-- Rollen-Zuordnungen beginnen gestern, damit ein Entzug per valid_to = now()
-- den Check valid_to > valid_from erfuellt.
-- =============================================================================

INSERT INTO app.teams (id, name, timezone) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Hook Team', 'Europe/Berlin'),
  ('99999999-9999-9999-9999-999999999999', 'Anderes Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, is_active, shirt_number) VALUES
  ('a1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Admin',          'a2000000-0000-0000-0000-000000000001', true,  NULL),
  ('a1000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Coach',          'a2000000-0000-0000-0000-000000000002', true,  NULL),
  ('a1000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Spieler',        'a2000000-0000-0000-0000-000000000003', true,  7),
  ('a1000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Inaktiv',        'a2000000-0000-0000-0000-000000000004', false, NULL),
  ('a1000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Ohne Rolle',     'a2000000-0000-0000-0000-000000000005', true,  NULL),
  ('a1000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Rolle beendet',  'a2000000-0000-0000-0000-000000000006', true,  NULL),
  ('a1000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'Athletik',       'a2000000-0000-0000-0000-000000000007', true,  NULL),
  ('a1000000-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'Zwei Rollen',    'a2000000-0000-0000-0000-000000000008', true,  NULL);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000001', 'admin',          now() - interval '1 day', NULL),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000002', 'coach',          now() - interval '1 day', NULL),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000003', 'player',         now() - interval '1 day', NULL),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000004', 'coach',          now() - interval '1 day', NULL),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000006', 'coach',          now() - interval '10 days', now() - interval '1 day'),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000007', 'athletic_coach', now() - interval '1 day', NULL),
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000008', 'physio',         now() - interval '1 day', NULL);

-- Event wie Supabase Auth es sendet (Pflicht-Claims, Stand Doku 2026-09-19).
CREATE FUNCTION app._t_event(p_user_id text, p_extra jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'user_id', p_user_id,
    'authentication_method', 'otp',
    'claims', jsonb_build_object(
      'iss', 'https://example.supabase.co/auth/v1',
      'aud', 'authenticated',
      'exp', 1790000000,
      'iat', 1789996400,
      'sub', p_user_id,
      'email', 'test@example.org',
      'phone', '',
      'role', 'authenticated',
      'aal', 'aal1',
      'amr', jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', 1789996400)),
      'session_id', 'b3f0c1de-0000-4000-8000-000000000001',
      'is_anonymous', false,
      'app_metadata', jsonb_build_object('provider', 'email'),
      'user_metadata', '{}'::jsonb
    ) || p_extra
  );
$$;

CREATE FUNCTION app._t_jwt(p_sub text, p_role text, p_team text DEFAULT '11111111-1111-1111-1111-111111111111')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text,
    true);
$$;


-- =============================================================================
-- 1. HOOK als supabase_auth_admin (ADR-015 Tests 1, 2, 3)
-- =============================================================================

SELECT has_function('app', 'custom_access_token_hook', ARRAY['jsonb'], 'Hook app.custom_access_token_hook(jsonb) existiert');

SET ROLE supabase_auth_admin;

SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) #>> '{claims,app_role}',
  'coach', 'Hook: Trainer bekommt app_role = coach');
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) #>> '{claims,team_id}',
  '11111111-1111-1111-1111-111111111111', 'Hook: Trainer bekommt team_id seines Teams');
SELECT is((app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) -> 'claims') - 'app_role' - 'team_id',
  app._t_event('a2000000-0000-0000-0000-000000000002') -> 'claims', 'Hook: Pflicht-Claims unveraendert');
SELECT ok(NOT (app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) ? 'error'),
  'Hook: kein error fuer Trainer');
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000003')) #>> '{claims,app_role}',
  'player', 'Hook: Spieler bekommt app_role = player');

-- Test 3: nie tenant_id, player_id, person_id
SELECT ok(NOT ((app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) -> 'claims') ?| ARRAY['tenant_id', 'player_id', 'person_id']),
  'Hook: Token ohne tenant_id, player_id, person_id');
SELECT ok(NOT ((app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002',
    '{"tenant_id":"11111111-1111-1111-1111-111111111111","player_id":"x"}'::jsonb)) -> 'claims') ?| ARRAY['tenant_id', 'player_id']),
  'Hook: eingeschleuster tenant_id und player_id werden entfernt');

-- Test 2: 403 bei keiner Person, inaktiv, keiner Rolle, beendeter Rolle, kaputter user_id
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-0000000000ff')) #>> '{error,http_code}',
  '403', 'Hook: 403 ohne gebundene Person');
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000004')) #>> '{error,http_code}',
  '403', 'Hook: 403 fuer inaktive Person');
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000005')) #>> '{error,http_code}',
  '403', 'Hook: 403 ohne Rolle');
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000006')) #>> '{error,http_code}',
  '403', 'Hook: 403 fuer beendete Rolle (valid_to vorbei)');
SELECT is(app.custom_access_token_hook(app._t_event('kein-uuid')) #>> '{error,http_code}',
  '403', 'Hook: 403 fuer ungueltige user_id');
SELECT ok(NOT (app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000004')) ? 'claims'),
  'Hook: bei 403 keine Claims');

-- Rechte der Hook-Rolle: nur freigegebene Spalten
SELECT throws_ok($$SELECT birth_date FROM app.persons LIMIT 1$$, '42501', NULL,
  'supabase_auth_admin darf persons.birth_date nicht lesen');
SELECT throws_ok($$SELECT count(*) FROM app.daily_checkins$$, '42501', NULL,
  'supabase_auth_admin darf daily_checkins nicht lesen');

RESET ROLE;


-- =============================================================================
-- 2. Mehrfachrollen: DB-Regel und Hook (ADR-015 Test 2, Entscheidung Chris)
-- =============================================================================

SELECT throws_ok(
  $$INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000008', 'doctor', now())$$,
  '23P01', NULL, 'DB-Regel: zweite aktive Rolle fuer dieselbe Person wird abgelehnt');

SELECT lives_ok(
  $$INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000006', 'physio', now() - interval '1 hour', NULL)$$,
  'DB-Regel: neue Rolle nach beendeter Rolle ist erlaubt');

-- Hook als zweite Verteidigung: Regel nur in dieser Transaktion aufheben.
ALTER TABLE app.role_assignments DROP CONSTRAINT role_assignments_one_active_role;
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-000000000008', 'doctor', now() - interval '1 day');
SET ROLE supabase_auth_admin;
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000008')) #>> '{error,message}',
  'Rolle nicht eindeutig. Bitte Admin informieren.', 'Hook: 403 bei zwei aktiven Rollen, keine gewinnt');
RESET ROLE;


-- =============================================================================
-- 3. Wer den Hook nicht ausfuehren darf (ADR-015 Test 7)
-- =============================================================================

SET ROLE authenticated;
SELECT throws_ok($$SELECT app.custom_access_token_hook('{}'::jsonb)$$, '42501', NULL,
  'authenticated darf den Hook nicht ausfuehren');
RESET ROLE;
SET ROLE anon;
SELECT throws_ok($$SELECT app.custom_access_token_hook('{}'::jsonb)$$, '42501', NULL,
  'anon darf den Hook nicht ausfuehren');
RESET ROLE;


-- =============================================================================
-- 4. DB-Waechter Stufe 2 mit echten RPC-Aufrufen als authenticated
-- =============================================================================

SET ROLE authenticated;

-- Trainer mit gueltigen Claims: Kader kommt
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000002', 'coach');
SELECT is(app.rpc_morning_ops() ->> 'kaderName', 'Hook Team', 'Trainer: rpc_morning_ops liefert den Kader');
SELECT is(jsonb_array_length(app.rpc_morning_ops() -> 'members'), 7, 'Trainer: rpc_morning_ops liefert alle 7 aktiven Personen');

-- Spieler: FORBIDDEN
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Spieler: rpc_morning_ops wirft FORBIDDEN');

-- Test 6: Claim coach fuer eine Person mit Rolle player
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000003', 'coach');
SELECT is(app.auth_is_staff(), false, 'Waechter: Claim coach fuer Spieler wird abgelehnt');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Waechter: gefaelschter Coach-Claim gibt FORBIDDEN');

-- Test 5: Rolle mit valid_to in der Vergangenheit
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000006', 'coach');
SELECT is(app.auth_has_role('coach'), false, 'Waechter: beendete Rolle coach wird abgelehnt');

-- Inaktive Person mit altem Claim
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000004', 'coach');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Waechter: inaktive Person gibt FORBIDDEN');

-- Falsches Team im Claim
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000002', 'coach', '99999999-9999-9999-9999-999999999999');
SELECT is(app.auth_team_id(), NULL::uuid, 'Waechter: Claim mit fremdem Team wird abgelehnt');

-- Ohne Claims (anon-Fall): false statt NULL, damit IF NOT ... sicher wirft
SELECT set_config('request.jwt.claims', '', true);
SELECT is(app.auth_has_role('coach'), false, 'Waechter: ohne Claims auth_has_role = false (nicht NULL)');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Waechter: ohne Claims FORBIDDEN statt leerer Kader');

-- Rollenentzug wirkt sofort
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000007', 'athletic_coach');
SELECT is(app.auth_is_staff(), true, 'Athletik vor Rollenentzug: Staff');
RESET ROLE;
UPDATE app.role_assignments SET valid_to = now() WHERE person_id = 'a1000000-0000-0000-0000-000000000007';
SET ROLE authenticated;
SELECT app._t_jwt('a2000000-0000-0000-0000-000000000007', 'athletic_coach');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Rollenentzug: derselbe Claim gibt sofort FORBIDDEN');


-- =============================================================================
-- 5. Shredding sperrt sofort (ADR-015 Test 4)
-- =============================================================================

SELECT app._t_jwt('a2000000-0000-0000-0000-000000000001', 'admin');
-- Seit AP-39b gibt rpc_shred_person die alte auth_user_id zurueck (vorher boolean),
-- damit das Auth Konto im zweiten Schritt ueber die Admin API geloescht werden kann.
SELECT is(app.rpc_shred_person('a1000000-0000-0000-0000-000000000002'),
  'a2000000-0000-0000-0000-000000000002'::uuid,
  'Admin shreddet den Trainer und bekommt dessen alte auth_user_id zurueck');

SELECT app._t_jwt('a2000000-0000-0000-0000-000000000002', 'coach');
SELECT is(app.auth_is_staff(), false, 'Nach Shredding: auth_is_staff() = false mit altem Claim');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN', 'Nach Shredding: rpc_morning_ops wirft sofort FORBIDDEN');
SELECT throws_ok($$SELECT app.rpc_list_team_members()$$, '42501', 'FORBIDDEN: persons.list',
  'Nach Shredding: Ablehnung ohne Team gibt FORBIDDEN, nicht 23502');

RESET ROLE;
SET ROLE supabase_auth_admin;
SELECT is(app.custom_access_token_hook(app._t_event('a2000000-0000-0000-0000-000000000002')) #>> '{error,http_code}',
  '403', 'Nach Shredding: Refresh bekommt vom Hook 403');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
