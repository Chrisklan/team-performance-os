-- =============================================================================
-- 19_body_map_history.pgtap.sql — Verlauf je Region und Physio Sicht (AP-45)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 10_auth_hook.sql,
-- 16_body_region.sql, 19_body_map_history.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Die Suite ist die Rollenmatrix: wer sieht was.
--   player           eigener Verlauf ja, Physio Sicht nein
--   physio, doctor   Physio Sicht ja (eigenes Team), eigener Verlauf nein
--   coach, athletic_coach, admin   beides nein
--   anon, ohne Claims              beides nein
-- Dazu: jedes Oeffnen der Physio Sicht steht im access_log und in der
-- Zugriffsuebersicht der Spielerin, eine Ablehnung und der eigene Verlauf nicht.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(75);

INSERT INTO app.teams (id, name, timezone, squad_type) VALUES
  ('19191919-1919-1919-1919-191919191919', 'Verlauf Kader',  'Europe/Berlin', 'frauen'),
  ('19191919-1919-1919-1919-191919190000', 'Anderer Kader',  'Europe/Berlin', 'frauen');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('f1000000-0000-0000-0000-000000000001', '19191919-1919-1919-1919-191919191919', 'Spielerin A',  'f2000000-0000-0000-0000-000000000001', 7),
  ('f1000000-0000-0000-0000-000000000002', '19191919-1919-1919-1919-191919191919', 'Spielerin B',  'f2000000-0000-0000-0000-000000000002', 9),
  ('f1000000-0000-0000-0000-000000000003', '19191919-1919-1919-1919-191919191919', 'Trainerin',    'f2000000-0000-0000-0000-000000000003', NULL),
  ('f1000000-0000-0000-0000-000000000004', '19191919-1919-1919-1919-191919191919', 'Physio',       'f2000000-0000-0000-0000-000000000004', NULL),
  ('f1000000-0000-0000-0000-000000000005', '19191919-1919-1919-1919-191919191919', 'Aerztin',      'f2000000-0000-0000-0000-000000000005', NULL),
  ('f1000000-0000-0000-0000-000000000006', '19191919-1919-1919-1919-191919191919', 'Athletik',     'f2000000-0000-0000-0000-000000000006', NULL),
  ('f1000000-0000-0000-0000-000000000007', '19191919-1919-1919-1919-191919191919', 'Admin',        'f2000000-0000-0000-0000-000000000007', NULL),
  ('f1000000-0000-0000-0000-000000000008', '19191919-1919-1919-1919-191919190000', 'Fremder Physio','f2000000-0000-0000-0000-000000000008', NULL),
  ('f1000000-0000-0000-0000-000000000009', '19191919-1919-1919-1919-191919190000', 'Fremde Spielerin','f2000000-0000-0000-0000-000000000009', 3);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', 'player',         now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000002', 'player',         now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000003', 'coach',          now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000004', 'physio',         now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000005', 'doctor',         now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000006', 'athletic_coach', now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000007', 'admin',          now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919190000', 'f1000000-0000-0000-0000-000000000008', 'physio',         now() - interval '1 day'),
  ('19191919-1919-1919-1919-191919190000', 'f1000000-0000-0000-0000-000000000009', 'player',         now() - interval '1 day');

CREATE FUNCTION app._t_today19() RETURNS date LANGUAGE sql AS $$
  SELECT (now() AT TIME ZONE 'Europe/Berlin')::date;
$$;

CREATE FUNCTION app._t_jwt19(p_sub text, p_role text, p_team text DEFAULT '19191919-1919-1919-1919-191919191919')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', p_team)::text,
    true);
$$;

-- Spielerin A: heute zwei Regionen (mit Tippunkt, Art und Zeichnung, die nicht
-- herauskommen duerfen), gestern Keine Beschwerden ([]), vorgestern ueberspringen
-- (NULL), dazu drei weitere Tage. Tag minus 27 ist der letzte im Fenster von 28 Tagen,
-- Tag minus 28 liegt schon draussen.
INSERT INTO app.daily_checkins (team_id, person_id, date, body_map, pain_max, sleep_quality) VALUES
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19(),
   '[{"region":"knie_l","pain":6,"art":"steif","point":[0.4123456,0.6123456],"svg":"weiblich_vorne@1"},{"region":"schulter_r","pain":2}]'::jsonb, 6, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 1,  '[]'::jsonb, 0, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 2,  NULL, NULL, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 3,  '[{"region":"knie_l","pain":4}]'::jsonb, 4, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 5,
   '[{"region":"ellbogen_unterarm_l","pain":3},{"region":"knie_l","pain":8}]'::jsonb, 8, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 27, '[{"region":"knie_l","pain":1}]'::jsonb, 1, 6),
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000001', app._t_today19() - 28, '[{"region":"schulter_r","pain":9}]'::jsonb, 9, 6),
  -- Spielerin B im selben Kader und eine Spielerin im anderen Kader: duerfen nirgends auftauchen.
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000002', app._t_today19(),      '[{"region":"knie_l","pain":10}]'::jsonb, 10, 6),
  ('19191919-1919-1919-1919-191919190000', 'f1000000-0000-0000-0000-000000000009', app._t_today19(),      '[{"region":"knie_l","pain":10}]'::jsonb, 10, 6);

-- ---------------------------------------------------------------------------
-- Aufbau und Rechte (10)
-- ---------------------------------------------------------------------------
SELECT has_function('public', 'rpc_my_body_map_history', ARRAY['integer'], 'Tuer fuer den eigenen Verlauf existiert');
SELECT has_function('public', 'rpc_body_map_region_reports', ARRAY['uuid', 'integer'], 'Tuer fuer die Physio Sicht existiert');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('rpc_my_body_map_history', 'rpc_body_map_region_reports')),
  2, 'Je Name genau eine Funktion, keine Ueberladung, die PostgREST mehrdeutig machte');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('rpc_my_body_map_history', 'rpc_body_map_region_reports')
             AND prosecdef),
  0, 'Beide Tueren sind SECURITY INVOKER');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'app'::regnamespace
             AND proname IN ('rpc_my_body_map_history', 'rpc_body_map_region_reports')
             AND prosecdef
             AND proconfig::text LIKE '%search_path%'),
  2, 'Die beiden app Funktionen sind SECURITY DEFINER mit festem search_path');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_my_body_map_history(integer)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.rpc_body_map_region_reports(uuid, integer)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'app.rpc_my_body_map_history(integer)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'app.rpc_body_map_region_reports(uuid, integer)', 'EXECUTE'),
  'anon darf keine der vier Funktionen aufrufen');
SELECT ok(has_function_privilege('authenticated', 'public.rpc_my_body_map_history(integer)', 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_body_map_region_reports(uuid, integer)', 'EXECUTE'),
  'authenticated darf beide Tueren aufrufen');
SELECT is((SELECT count(*)::int FROM pg_proc p, aclexplode(p.proacl) a
           WHERE p.proname IN ('rpc_my_body_map_history', 'rpc_body_map_region_reports')
             AND p.pronamespace IN ('public'::regnamespace, 'app'::regnamespace)
             AND a.grantee = 0),
  0, 'PUBLIC hat keine Rechte, die Default ACL ist nicht mehr im Spiel');
SELECT is((SELECT proargnames FROM pg_proc
           WHERE oid = 'app.rpc_my_body_map_history(integer)'::regprocedure),
  ARRAY['p_days'], 'Der eigene Verlauf hat keinen Parameter fuer eine Person, nur das Fenster');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('rpc_my_body_map_history', 'rpc_body_map_region_reports')
             AND provolatile = 'v'),
  2, 'Beide Tueren sind VOLATILE (die Physio Sicht schreibt, der Verlauf ruft den Ablehnungs Log)');

-- ---------------------------------------------------------------------------
-- Eigener Verlauf (Spielerin A) (14)
-- ---------------------------------------------------------------------------
SELECT set_config('tpos.log_before', (SELECT count(*)::text FROM app.access_log), true);

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000001', 'player');
SELECT set_config('tpos.hist28', public.rpc_my_body_map_history(28)::text, true);
SELECT set_config('tpos.hist7',  public.rpc_my_body_map_history(7)::text, true);
SELECT set_config('tpos.histdef', public.rpc_my_body_map_history()::text, true);
RESET ROLE;

SELECT is((current_setting('tpos.hist28')::jsonb -> 'checkins') IS NOT NULL
      AND jsonb_array_length(current_setting('tpos.hist28')::jsonb -> 'checkins') = 6, true,
  'Sechs Check-in Tage im Fenster von 28 Tagen (Tag minus 28 ist draussen)');
SELECT is(current_setting('tpos.histdef')::jsonb -> 'days', to_jsonb(28),
  'Ohne Angabe gilt das Fenster von 28 Tagen');
SELECT is((current_setting('tpos.hist28')::jsonb -> 'checkins' -> 0 ->> 'date')::date, app._t_today19() - 27,
  'Der erste Tag ist minus 27, der Rand liegt drin');
SELECT is((current_setting('tpos.hist28')::jsonb -> 'checkins' -> 5 ->> 'date')::date, app._t_today19(),
  'Der letzte Tag ist heute, aufsteigend sortiert');
SELECT is((SELECT jsonb_agg(c -> 'answered' ORDER BY (c ->> 'date')::date)
             FROM jsonb_array_elements(current_setting('tpos.hist28')::jsonb -> 'checkins') c),
  '[true, true, true, false, true, true]'::jsonb,
  'answered je Tag: nur der uebersprungene Tag (NULL) ist false, Keine Beschwerden ([]) ist true');
SELECT is((SELECT c -> 'regions' FROM jsonb_array_elements(current_setting('tpos.hist28')::jsonb -> 'checkins') c
            WHERE (c ->> 'date')::date = app._t_today19() - 1),
  '[]'::jsonb, 'Keine Beschwerden liefert eine leere Regionsliste');
SELECT is((SELECT c -> 'regions' FROM jsonb_array_elements(current_setting('tpos.hist28')::jsonb -> 'checkins') c
            WHERE (c ->> 'date')::date = app._t_today19()),
  '[{"pain": 6, "region": "knie_l"}, {"pain": 2, "region": "schulter_r"}]'::jsonb,
  'Heute zwei Regionen mit Wert, ohne Tippunkt, Art und Zeichnung');
SELECT is((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(current_setting('tpos.hist28')::jsonb) k),
  ARRAY['checkins', 'days', 'from', 'to'], 'Die Antwort traegt genau vier Felder');
SELECT is((SELECT array_agg(DISTINCT k ORDER BY k)
             FROM jsonb_array_elements(current_setting('tpos.hist28')::jsonb -> 'checkins') c,
                  jsonb_object_keys(c) k),
  ARRAY['answered', 'date', 'regions'], 'Jeder Tag traegt genau Datum, answered und Regionen');
SELECT is(position('0.4123456' IN current_setting('tpos.hist28')) + position('weiblich_vorne' IN current_setting('tpos.hist28')), 0,
  'Der Tippunkt und die Zeichnung tauchen in der Antwort nirgends auf');
SELECT is(position('"pain": 10' IN current_setting('tpos.hist28')), 0,
  'Spielerin B (Wert 10) und die Spielerin im anderen Kader kommen nicht vor');
SELECT is(jsonb_array_length(current_setting('tpos.hist7')::jsonb -> 'checkins'), 5,
  'Fenster 7 Tage: minus 5, minus 3, minus 2, minus 1 und heute');
SELECT is((current_setting('tpos.hist28')::jsonb ->> 'from')::date, app._t_today19() - 27,
  'from ist der Beginn des Fensters in der Zeitzone des Teams');
SELECT is((SELECT count(*)::text FROM app.access_log), current_setting('tpos.log_before'),
  'Der eigene Verlauf schreibt nichts in den access_log');

-- Ungueltiges Fenster und Rollen (8)
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000001', 'player');
SELECT throws_ok($$SELECT public.rpc_my_body_map_history(0)$$,   '22023', 'INVALID: body_map_history.days', 'Fenster 0 wird abgelehnt');
SELECT throws_ok($$SELECT public.rpc_my_body_map_history(91)$$,  '22023', 'INVALID: body_map_history.days', 'Fenster 91 wird abgelehnt');
SELECT throws_ok($$SELECT public.rpc_my_body_map_history(NULL)$$, '22023', 'INVALID: body_map_history.days', 'Fenster NULL wird abgelehnt');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000003', 'coach');
SELECT is((SELECT public.rpc_my_body_map_history()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Trainerin: eigener Verlauf abgewiesen');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_my_body_map_history()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: der Weg der Spielerin ist nicht seiner');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000007', 'admin');
SELECT is((SELECT public.rpc_my_body_map_history()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Admin: abgewiesen');
RESET ROLE;
SET ROLE anon;
SELECT throws_ok($$SELECT public.rpc_my_body_map_history()$$, '42501', NULL, 'anon: abgewiesen');
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT public.rpc_my_body_map_history()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Ohne Claims FORBIDDEN');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Physio Sicht (Physio, Spielerin A) (20)
-- ---------------------------------------------------------------------------
SELECT set_config('tpos.log_before', (SELECT count(*)::text FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000001'), true);

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT set_config('tpos.rep28', public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', 28)::text, true);
RESET ROLE;

SELECT is((SELECT count(*)::text FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000001'),
  (current_setting('tpos.log_before')::int + 1)::text,
  'Ein Oeffnen der Physio Sicht schreibt genau eine Zeile in den access_log');
SELECT is((SELECT row(al.actor_id, al.actor_role::text, al.resource, al.action, al.scope_date)::text
             FROM app.access_log al
            WHERE al.subject_id = 'f1000000-0000-0000-0000-000000000001'
            ORDER BY al.id DESC LIMIT 1),
  row('f1000000-0000-0000-0000-000000000004'::uuid, 'physio', 'daily_checkins.body_map', 'read', app._t_today19() - 27)::text,
  'Die Zeile nennt Physio als Handelnden und Rolle, die Ressource, read und den Beginn des Fensters');
SELECT is(current_setting('tpos.rep28')::jsonb ->> 'answeredDays', '5',
  'answeredDays zaehlt Tage mit beantworteter Body Map: fuenf (NULL und Tag minus 28 zaehlen nicht)');
SELECT is((SELECT jsonb_agg(r ->> 'region') FROM jsonb_array_elements(current_setting('tpos.rep28')::jsonb -> 'regions') r),
  '["schulter_r", "knie_l", "ellbogen_unterarm_l"]'::jsonb,
  'Reihenfolge ist die des Katalogs, keine Rangfolge nach Haeufigkeit oder Wert');
SELECT is((SELECT r FROM jsonb_array_elements(current_setting('tpos.rep28')::jsonb -> 'regions') r WHERE r ->> 'region' = 'knie_l'),
  jsonb_build_object('region', 'knie_l', 'label', 'Knie links', 'reports', 4, 'highest', 8,
                     'lastDate', app._t_today19(), 'legacy', false),
  'Knie links: vier Tage mit Meldung, hoechster Wert 8, letzte Meldung heute, keine Altregion');
SELECT is((SELECT r ->> 'legacy' FROM jsonb_array_elements(current_setting('tpos.rep28')::jsonb -> 'regions') r WHERE r ->> 'region' = 'ellbogen_unterarm_l'),
  'true', 'Ein Altschluessel steht daneben und ist als solcher gekennzeichnet');
SELECT is((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(current_setting('tpos.rep28')::jsonb) k),
  ARRAY['answeredDays', 'days', 'from', 'personId', 'regions', 'to'],
  'Die Antwort traegt genau sechs Felder, keinen Mittelwert, keine Bewertung');
SELECT is((SELECT array_agg(DISTINCT k ORDER BY k)
             FROM jsonb_array_elements(current_setting('tpos.rep28')::jsonb -> 'regions') r, jsonb_object_keys(r) k),
  ARRAY['highest', 'label', 'lastDate', 'legacy', 'region', 'reports'],
  'Jede Region traegt genau sechs Felder, ohne Tippunkt, Art und Zeichnung');
SELECT is(position('0.4123456' IN current_setting('tpos.rep28')) + position('weiblich_vorne' IN current_setting('tpos.rep28')), 0,
  'Der Tippunkt wird in der Physio Sicht nicht gelesen');

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000005', 'doctor');
SELECT set_config('tpos.rep30', public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', 30)::text, true);
RESET ROLE;
SELECT is((SELECT r ->> 'reports' || '/' || (r ->> 'highest') FROM jsonb_array_elements(current_setting('tpos.rep30')::jsonb -> 'regions') r WHERE r ->> 'region' = 'schulter_r'),
  '2/9', 'Aerztin darf auch. Fenster 30 Tage nimmt den Tag minus 28 mit (Schulter rechts: zwei Tage, hoechster Wert 9)');
SELECT is((SELECT row(al.actor_role::text, al.scope_date)::text FROM app.access_log al
            WHERE al.subject_id = 'f1000000-0000-0000-0000-000000000001'
            ORDER BY al.id DESC LIMIT 1),
  row('doctor', app._t_today19() - 29)::text,
  'Die zweite Zeile nennt die Rolle doctor und den Beginn des 30 Tage Fensters');
SELECT is((SELECT count(*)::text FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000001'),
  (current_setting('tpos.log_before')::int + 2)::text,
  'Jedes Oeffnen ist eine eigene Zeile, keine Zusammenfassung');

-- Zugriffsuebersicht der Spielerin
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000001', 'player');
SELECT is((SELECT count(*)::int FROM app.rpc_get_my_access_log()
            WHERE resource = 'daily_checkins.body_map' AND actor_role IN ('physio', 'doctor')),
  2, 'Beide Zugriffe stehen in der Zugriffsuebersicht der Spielerin A');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000002', 'player');
SELECT is((SELECT count(*)::int FROM app.rpc_get_my_access_log()
            WHERE actor_role IN ('physio', 'doctor')),
  0, 'Spielerin B sieht diese Zugriffe nicht');
RESET ROLE;

-- Ungueltiges Fenster (3)
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT throws_ok($$SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', 0)$$,
  '22023', 'INVALID: body_map_history.days', 'Physio Sicht: Fenster 0 abgelehnt');
SELECT throws_ok($$SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', 91)$$,
  '22023', 'INVALID: body_map_history.days', 'Physio Sicht: Fenster 91 abgelehnt');
SELECT throws_ok($$SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', NULL)$$,
  '22023', 'INVALID: body_map_history.days', 'Physio Sicht: Fenster NULL abgelehnt');
RESET ROLE;

-- Wer nicht darf, bekommt FORBIDDEN und hinterlaesst keine Zeile (9)
SELECT set_config('tpos.log_before', (SELECT count(*)::text FROM app.access_log), true);

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000003', 'coach');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Trainerin: Physio Sicht abgewiesen (Medizin Gate)');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000006', 'athletic_coach');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Athletiktrainerin: abgewiesen');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000007', 'admin');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Admin: abgewiesen, Admin ist kein Medizin Leser');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000001', 'player');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Spielerin: auch fuer die eigene Id abgewiesen, ihr Weg ist der Verlauf');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000008', 'physio', '19191919-1919-1919-1919-191919190000');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio aus dem anderen Kader: Spielerin A abgewiesen');
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000009')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: Spielerin aus dem anderen Kader abgewiesen');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-00000000dead')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: unbekannte Id gibt dieselbe Antwort, kein Orakel');
SELECT is((SELECT public.rpc_body_map_region_reports(NULL)),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: NULL abgewiesen');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000003')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: eine Person ohne Rolle player (die Trainerin) abgewiesen');
RESET ROLE;

SET ROLE anon;
SELECT throws_ok($$SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')$$,
  '42501', NULL, 'anon: abgewiesen');
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Ohne Claims FORBIDDEN');
RESET ROLE;

SELECT is((SELECT count(*)::text FROM app.access_log), current_setting('tpos.log_before'),
  'Keine der Ablehnungen hat eine Zeile in den access_log geschrieben');

-- ---------------------------------------------------------------------------
-- Gegenlesung 2026-09-21 (Rollen und Protokoll) (14)
--
-- Wer die Rolle nur behauptet, kommt nicht hinein: die Helper bestaetigen den
-- Claim gegen die Datenbank. Und das Protokoll ueberlebt den Loeschpfad nicht
-- als Zeile ueber eine Person, die es nicht mehr gibt.
-- ---------------------------------------------------------------------------

-- Ein Oeffnen legt keine Kopie im audit_log an: access_log traegt keinen
-- Audit Trigger, und in der Zeile steht kein Gesundheitsinhalt.
SELECT set_config('tpos.audit_before', (SELECT count(*)::text FROM app.audit_log), true);
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001', 28);
RESET ROLE;
SELECT is((SELECT count(*)::text FROM app.audit_log), current_setting('tpos.audit_before'),
  'Ein Oeffnen der Physio Sicht erzeugt keine neue Zeile im audit_log (keine Kopie von Gesundheitsdaten)');

-- Spielerin C: Physio oeffnet, Admin shreddert, danach ist die Sicht zu.
INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('f1000000-0000-0000-0000-000000000010', '19191919-1919-1919-1919-191919191919', 'Spielerin C', 'f2000000-0000-0000-0000-000000000010', 11);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000010', 'player', now() - interval '1 day');
INSERT INTO app.daily_checkins (team_id, person_id, date, body_map, pain_max, sleep_quality) VALUES
  ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000010', app._t_today19(),
   '[{"region":"knie_r","pain":5}]'::jsonb, 5, 6);

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000010', 28);
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000010'), 1,
  'Spielerin C: das Oeffnen steht im access_log');

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000007', 'admin');
SELECT app.rpc_shred_person('f1000000-0000-0000-0000-000000000010');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000010'), 0,
  'Der Shred raeumt die Zeile der Physio Sicht mit ab (Betroffenenzeile)');

SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000010')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: geshredderte Spielerin abgewiesen, obwohl ihre Rolle player weiter gilt');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.access_log WHERE subject_id = 'f1000000-0000-0000-0000-000000000010'), 0,
  'Nach dem Shred entsteht keine neue Zeile ueber die geshredderte Person');

-- Deaktivierte Spielerin (Spielerin B), nicht geshreddert: gleiche Antwort.
UPDATE app.persons SET is_active = false WHERE id = 'f1000000-0000-0000-0000-000000000002';
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000002')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio: deaktivierte Spielerin abgewiesen');
RESET ROLE;

-- Der Claim allein reicht nicht: die Datenbank bestaetigt ihn bei jedem Aufruf.
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000003', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Token sagt physio, die Datenbank sagt coach: abgewiesen');
RESET ROLE;

-- Personalunion: eine Person hat keine zweite Rolle neben der aktiven (ADR-009 Punkt 4).
SELECT throws_ok($$INSERT INTO app.role_assignments (team_id, person_id, role, valid_from)
  VALUES ('19191919-1919-1919-1919-191919191919', 'f1000000-0000-0000-0000-000000000003', 'physio', now())$$,
  '23P01', NULL, 'Personalunion: die Trainerin bekommt keine zweite, gleichzeitige Rolle physio');

-- Physio deaktiviert, dann Rolle beendet: der noch gueltige Token oeffnet nichts mehr.
UPDATE app.persons SET is_active = false WHERE id = 'f1000000-0000-0000-0000-000000000004';
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Physio deaktiviert: der noch gueltige Token oeffnet nichts');
RESET ROLE;
UPDATE app.persons SET is_active = true WHERE id = 'f1000000-0000-0000-0000-000000000004';

UPDATE app.role_assignments SET valid_to = now() - interval '1 second'
 WHERE person_id = 'f1000000-0000-0000-0000-000000000004';
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Rolle physio beendet: der noch gueltige Token oeffnet nichts');
RESET ROLE;
UPDATE app.role_assignments SET valid_to = NULL
 WHERE person_id = 'f1000000-0000-0000-0000-000000000004';

-- Der Shred der Medizinperson: ihre Zeilen bleiben als Handelnde stehen (Entscheidung
-- AP-39), die Spielerin sieht sie weiter, nur der Name ist weg.
SELECT set_config('tpos.actor_rows', (SELECT count(*)::text FROM app.access_log
                                       WHERE actor_id = 'f1000000-0000-0000-0000-000000000004'), true);
SELECT set_config('tpos.a_rows', (SELECT count(*)::text FROM app.access_log
                                   WHERE actor_id = 'f1000000-0000-0000-0000-000000000004'
                                     AND subject_id = 'f1000000-0000-0000-0000-000000000001'
                                     AND resource = 'daily_checkins.body_map'), true);
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000007', 'admin');
SELECT app.rpc_shred_person('f1000000-0000-0000-0000-000000000004');
RESET ROLE;
SELECT ok(current_setting('tpos.actor_rows')::int > 0
      AND (SELECT count(*)::int FROM app.access_log WHERE actor_id = 'f1000000-0000-0000-0000-000000000004')
          = current_setting('tpos.actor_rows')::int,
  'Shred der Medizinperson: ihre Zeilen als Handelnde bleiben unveraendert stehen');
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000001', 'player');
SELECT is((SELECT count(*)::int FROM app.rpc_get_my_access_log()
            WHERE actor_id = 'f1000000-0000-0000-0000-000000000004' AND resource = 'daily_checkins.body_map'),
  current_setting('tpos.a_rows')::int,
  'Spielerin A sieht die Zugriffe der geshredderten Medizinperson weiter');
RESET ROLE;
SELECT ok((SELECT display_name LIKE 'SCRAPED-%' FROM app.persons WHERE id = 'f1000000-0000-0000-0000-000000000004'),
  'Die Zeile der Medizinperson ist anonymisiert, die id bleibt der Verweis');
SET ROLE authenticated;
SELECT app._t_jwt19('f2000000-0000-0000-0000-000000000004', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('f1000000-0000-0000-0000-000000000001')),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: daily_checkins.body_map', 'details', NULL, 'hint', NULL),
  'Geshredderte Medizinperson: der Token oeffnet nichts mehr');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
