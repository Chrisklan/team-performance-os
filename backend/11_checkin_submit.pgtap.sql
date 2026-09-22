-- =============================================================================
-- 11_checkin_submit.pgtap.sql — app.rpc_submit_checkin (AP-33, ADR-016)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, 16_body_region.sql, 11_checkin_submit.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(42);

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
      '[{"region":"knie_l","pain":4,"art":"muskulaer"},{"region":"lws_kreuz","pain":2}]'::jsonb)$$,
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
SELECT is((SELECT app.rpc_submit_checkin(current_date, 480, 8, 8, 8, 2, 8, 8, 8, NULL)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.submit', 'details', NULL, 'hint', NULL),
  'Trainer darf keinen Check-In abgeben');

-- Datum
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date + 1)$$,
  '42501', 'FORBIDDEN: daily_checkins.date', 'Datum in der Zukunft abgelehnt');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date - 3)$$,
  '42501', 'FORBIDDEN: daily_checkins.date', 'Datum aelter als 2 Tage abgelehnt');
SELECT lives_ok($$SELECT app.rpc_submit_checkin(current_date - 2, 450, 6, 6, 6, 4, 6, 6, 6, NULL)$$,
  'Offline-Nachtrag 2 Tage zurueck erlaubt');

-- Body Map
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '{"region":"knie_l"}'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map', 'Body Map muss ein Array sein');
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '[{"region":"knie_l","pain":11}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map', 'Schmerzwert ueber 10 abgelehnt');

-- ---------------------------------------------------------------------------
-- AP-43: Region gegen app.body_region
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knee_left","pain":3}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.region',
  'Unbekannte Region abgelehnt. Vorher ging knee_left neben knie_l durch und die Historie zerfiel');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"Knie links","pain":3}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.region', 'Auch die Beschriftung selbst ist kein Schluessel');
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"oberschenkel_hinten_l","pain":5}]'::jsonb)$$,
  'Neuer Schluessel aus dem Zuschnitt von AP-43a wird angenommen');

-- Altschluessel: nicht mehr waehlbar, aber aus der Offline Warteschlange
-- einer alten App weiter zulaessig (Entscheidung Chris 2026-09-21).
SELECT is((SELECT is_selectable FROM app.body_region WHERE key = 'hand_l'), false,
  'hand_l ist ein Altschluessel ohne Flaeche auf der Silhouette');
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"hand_l","pain":6}]'::jsonb)$$,
  'Altschluessel wird angenommen. Ablehnen hiesse, Gesundheitsdaten aus der Warteschlange still zu verlieren');

-- Der Abschalter: active_to macht einen Schluessel fuer neue Check-Ins ungueltig,
-- ohne die Zeile und damit die Beschriftung alter Check-Ins zu verlieren.
RESET ROLE;
UPDATE app.body_region SET active_to = current_date WHERE key = 'hand_l';
SET ROLE authenticated;
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"hand_l","pain":6}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.region',
  'Abgeschalteter Schluessel wird in neuen Check-Ins abgelehnt');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.body_region WHERE key = 'hand_l'), 1,
  'Die abgeschaltete Zeile bleibt stehen, sonst waeren alte Check-Ins nicht mehr beschriftbar');
UPDATE app.body_region SET active_to = NULL WHERE key = 'hand_l';
SET ROLE authenticated;
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');

-- ---------------------------------------------------------------------------
-- AP-43: Tippunkt und Figur
-- ---------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, 480, 8, 7, 6, 3, 8, 7, 8,
      '[{"region":"knie_l","pain":4,"art":"gelenkig","point":[0.42,0.71],"svg":"weiblich_vorne@1"}]'::jsonb)$$,
  'Check-In mit Tippunkt und Figur wird gespeichert');
RESET ROLE;
SELECT is(
  (SELECT body_map -> 0 -> 'point' FROM app.daily_checkins
    WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  '[0.42, 0.71]'::jsonb, 'Der Tippunkt liegt normiert in der Zeile, nicht in Pixeln');
SELECT is(
  (SELECT body_map -> 0 ->> 'svg' FROM app.daily_checkins
    WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  'weiblich_vorne@1', 'Die Figur steht mit Version daneben, sonst zeigt der Punkt spaeter irgendwohin');
SELECT is(
  (SELECT pain_max::int FROM app.daily_checkins
    WHERE person_id = 'b1000000-0000-0000-0000-000000000003' AND date = current_date),
  4, 'pain_max liest weiter nur pain. Mit dem Tippunkt wird nichts gerechnet (Modul Abschnitt 8)');
SET ROLE authenticated;
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');

SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[0,1],"svg":"neutral_hinten@12"}]'::jsonb)$$,
  'Die Raender 0 und 1 gehoeren dazu, die Version ist frei');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[1.5,0.2],"svg":"neutral_vorne@1"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.point', 'Punkt ausserhalb von 0 bis 1 abgelehnt');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[-0.01,0.2],"svg":"neutral_vorne@1"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.point', 'Negativer Punkt abgelehnt');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[0.3,0.4,0.5],"svg":"neutral_vorne@1"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.point', 'Genau zwei Zahlen, nicht drei');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":["0.3","0.4"],"svg":"neutral_vorne@1"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.point', 'Zeichenketten sind keine Koordinaten');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[0.3,0.4]}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.svg',
  'Punkt ohne Figur abgelehnt. Er zeigt auf keine bestimmte Kontur und waere nach dem naechsten Redesign wertlos');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"point":[0.3,0.4],"svg":"front_neutral@1"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.svg',
  'Unbekannte Variante abgelehnt. Die sechs Figuren heissen weiblich_vorne bis neutral_hinten');
SELECT throws_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4,"svg":"neutral_vorne"}]'::jsonb)$$,
  '22023', 'INVALID: daily_checkins.body_map.svg', 'Figur ohne Version abgelehnt');
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
      '[{"region":"knie_l","pain":4}]'::jsonb)$$,
  'Beides bleibt optional: eine Region ohne Punkt und ohne Figur geht weiter durch');

-- ---------------------------------------------------------------------------
-- Medizin Gate (ADR-009): am Tippunkt aendert sich daran nichts
-- ---------------------------------------------------------------------------
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok($$SELECT body_map FROM app.daily_checkins LIMIT 1$$, '42501', NULL,
  'Trainer: body_map bleibt gesperrt, auch mit Tippunkt darin');
SELECT throws_ok($$SELECT pain_max FROM app.daily_checkins LIMIT 1$$, '42501', NULL,
  'Trainer: pain_max bleibt gesperrt');
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');

-- Ohne Claims
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT app.rpc_submit_checkin(current_date)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.submit', 'details', NULL, 'hint', NULL),
  'Ohne Claims FORBIDDEN');

-- Nach Shredding sofort gesperrt
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000001', 'admin');
SELECT app.rpc_shred_person('b1000000-0000-0000-0000-000000000003');
SELECT app._t_jwt('b2000000-0000-0000-0000-000000000003', 'player');
SELECT is((SELECT app.rpc_submit_checkin(current_date)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.submit', 'details', NULL, 'hint', NULL),
  'Nach Shredding: Check-In sofort FORBIDDEN');
RESET ROLE;

SET ROLE anon;
SELECT throws_ok($$SELECT app.rpc_submit_checkin(current_date)$$, '42501', NULL, 'anon darf die RPC nicht ausfuehren');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
