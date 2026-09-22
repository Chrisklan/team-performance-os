-- =============================================================================
-- 20_denial_answer.pgtap.sql — Die Ablehnung ueberlebt den Commit (AP-45d)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 10_auth_hook.sql,
-- 16_body_region.sql, 11, 13, 17, 18, 19, 20_denial_answer.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Diese Suite prueft den Vertrag aus Option A (Audit 2026-09-21, Abschnitt 9.2):
-- eine abgelehnte Tuer wirft nicht mehr, sondern antwortet mit dem Fehlerobjekt,
-- setzt response.status auf 403 und schreibt die Zeile in app.access_denials.
--
-- Was sie NICHT beweisen kann: dass die Zeile den Commit ueberlebt. pgTAP laeuft in
-- einer Transaktion, jedes Ergebnis rollt am Ende zurueck. Der Beleg dafuer ist die
-- Autocommit Messung im Klon der Test DB (Audit Abschnitt 9.4). Was hier steht, ist
-- der halbe Beweis: die Zeile ist da, waehrend die Antwort schon feststeht, und es
-- gibt keine Ausnahme mehr, die sie mitreisst.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(34);

INSERT INTO app.teams (id, name, timezone, squad_type) VALUES
  ('20202020-2020-2020-2020-202020202020', 'Deny Kader', 'Europe/Berlin', 'frauen');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('d1000000-0000-0000-0000-000000000001', '20202020-2020-2020-2020-202020202020', 'Spielerin', 'd2000000-0000-0000-0000-000000000001', 7),
  ('d1000000-0000-0000-0000-000000000002', '20202020-2020-2020-2020-202020202020', 'Trainerin', 'd2000000-0000-0000-0000-000000000002', NULL),
  ('d1000000-0000-0000-0000-000000000003', '20202020-2020-2020-2020-202020202020', 'Physio',    'd2000000-0000-0000-0000-000000000003', NULL);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('20202020-2020-2020-2020-202020202020', 'd1000000-0000-0000-0000-000000000001', 'player', now() - interval '1 day'),
  ('20202020-2020-2020-2020-202020202020', 'd1000000-0000-0000-0000-000000000002', 'coach',  now() - interval '1 day'),
  ('20202020-2020-2020-2020-202020202020', 'd1000000-0000-0000-0000-000000000003', 'physio', now() - interval '1 day');

CREATE FUNCTION app._t_jwt20(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '20202020-2020-2020-2020-202020202020')::text,
    true);
$$;

-- Das Fehlerobjekt, wie es der Vertrag festlegt. Die Suite schreibt es genau einmal
-- hin und vergleicht danach dagegen, damit eine spaetere Aenderung an einer Stelle
-- auffaellt und nicht an zwoelf.
CREATE FUNCTION app._t_body20(p_message text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('code', '42501', 'message', p_message,
                            'details', NULL, 'hint', NULL);
$$;

CREATE FUNCTION app._t_status20() RETURNS text LANGUAGE sql AS $$
  SELECT current_setting('response.status', true);
$$;

-- ---------------------------------------------------------------------------
-- 1. Bausteine (8)
-- ---------------------------------------------------------------------------
SELECT has_function('app', 'deny', ARRAY['text', 'text'], 'app.deny existiert');
SELECT is((SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p
           WHERE p.oid = 'app.deny(text,text)'::regprocedure),
  'vtrue', 'app.deny ist VOLATILE und SECURITY DEFINER');
SELECT ok(NOT has_function_privilege('anon', 'app.deny(text,text)', 'EXECUTE')
      AND NOT has_function_privilege('authenticated', 'app.deny(text,text)', 'EXECUTE'),
  'app.deny ist weder fuer anon noch fuer authenticated ausfuehrbar, nur die Waechter rufen sie');

SELECT has_function('app', 'is_denial', ARRAY['jsonb'], 'app.is_denial existiert');
SELECT is((SELECT p.provolatile::text || p.prosecdef::text FROM pg_proc p
           WHERE p.oid = 'app.is_denial(jsonb)'::regprocedure),
  'ifalse', 'app.is_denial ist IMMUTABLE und SECURITY INVOKER, sie liest nichts');
SELECT ok(has_function_privilege('authenticated', 'app.is_denial(jsonb)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'app.is_denial(jsonb)', 'EXECUTE'),
  'authenticated darf app.is_denial, anon nicht: die Tueren sind SECURITY INVOKER');

SELECT is((SELECT count(*)::int FROM pg_proc p
           WHERE p.oid IN ('public.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)'::regprocedure,
                           'public.rpc_my_body_map_figure()'::regprocedure,
                           'public.rpc_set_my_body_map_figure(text)'::regprocedure,
                           'public.rpc_my_body_map_history(integer)'::regprocedure,
                           'public.rpc_body_map_region_reports(uuid,integer)'::regprocedure)
             AND p.prorettype = 'jsonb'::regtype
             AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
             AND NOT p.prosecdef),
  5, 'Alle fuenf Tueren geben jsonb zurueck, sind plpgsql und SECURITY INVOKER');

-- PostgREST faehrt immutable und stable Funktionen in einer READ ONLY Transaktion.
-- Eine Tuer, die eine Ablehnung schreibt, kann dort nicht stehen (Fehler 25006).
SELECT is((SELECT count(*)::int FROM pg_proc p
           WHERE p.oid IN ('public.rpc_submit_checkin(date,numeric,integer,integer,integer,integer,integer,integer,integer,jsonb)'::regprocedure,
                           'public.rpc_my_body_map_figure()'::regprocedure,
                           'public.rpc_set_my_body_map_figure(text)'::regprocedure,
                           'public.rpc_my_body_map_history(integer)'::regprocedure,
                           'public.rpc_body_map_region_reports(uuid,integer)'::regprocedure)
             AND p.provolatile = 'v'),
  5, 'Alle fuenf Tueren sind VOLATILE, keine faehrt in einer READ ONLY Transaktion');

-- ---------------------------------------------------------------------------
-- 2. app.is_denial trennt sauber (4)
-- ---------------------------------------------------------------------------
SELECT ok(app.is_denial(app._t_body20('FORBIDDEN: irgendwas')),
  'is_denial erkennt das Fehlerobjekt');
SELECT ok(NOT app.is_denial('{"from": "2026-09-01", "to": "2026-09-28", "days": 28, "checkins": []}'::jsonb),
  'is_denial ist falsch fuer eine Erfolgsantwort');
SELECT ok(NOT app.is_denial(NULL),
  'is_denial ist falsch fuer NULL');
SELECT ok(NOT app.is_denial(to_jsonb('d1000000-0000-0000-0000-000000000001'::uuid)),
  'is_denial ist falsch fuer einen JSON String, den Erfolgsfall von rpc_submit_checkin');

-- ---------------------------------------------------------------------------
-- 3. Tuer 1: public.rpc_submit_checkin, Trainerin (4)
-- ---------------------------------------------------------------------------
SELECT app._t_jwt20('d2000000-0000-0000-0000-000000000002', 'coach');
SELECT set_config('response.status', '', true);

SELECT lives_ok($$SELECT public.rpc_submit_checkin(current_date)$$,
  'Die abgelehnte Tuer wirft nicht mehr, sie antwortet');
SELECT is((SELECT public.rpc_submit_checkin(current_date)),
  app._t_body20('FORBIDDEN: daily_checkins.submit'),
  'Trainerin auf der Check-In Tuer: genau das Fehlerobjekt aus dem Vertrag');
SELECT is(app._t_status20(), '403',
  'Die Tuer hat response.status auf 403 gesetzt');
SELECT ok((SELECT count(*) FROM app.access_denials
            WHERE resource = 'daily_checkins.submit'
              AND actor_role = 'coach'
              AND actor_id = 'd1000000-0000-0000-0000-000000000002'
              AND team_id = '20202020-2020-2020-2020-202020202020') >= 1,
  'Die Ablehnung steht in app.access_denials, mit Person, Rolle und Team');

-- ---------------------------------------------------------------------------
-- 4. Tuer 2: public.rpc_my_body_map_history, Trainerin (3)
-- ---------------------------------------------------------------------------
SELECT set_config('response.status', '', true);
SELECT is((SELECT public.rpc_my_body_map_history()),
  app._t_body20('FORBIDDEN: daily_checkins.body_map'),
  'Trainerin auf dem eigenen Verlauf: Fehlerobjekt');
SELECT is(app._t_status20(), '403', 'Status 403');
SELECT ok((SELECT count(*) FROM app.access_denials
            WHERE resource = 'daily_checkins.body_map' AND actor_role = 'coach') >= 1,
  'Zeile in app.access_denials');

-- ---------------------------------------------------------------------------
-- 5. Tuer 3: public.rpc_body_map_region_reports, Trainerin (3)
-- ---------------------------------------------------------------------------
SELECT set_config('response.status', '', true);
SELECT is((SELECT public.rpc_body_map_region_reports('d1000000-0000-0000-0000-000000000001')),
  app._t_body20('FORBIDDEN: daily_checkins.body_map'),
  'Trainerin auf der Physio Sicht: Fehlerobjekt');
SELECT is(app._t_status20(), '403', 'Status 403');
SELECT ok((SELECT count(*) FROM app.access_denials WHERE actor_role = 'coach') >= 3,
  'Jede der drei Ablehnungen hat eine eigene Zeile geschrieben');

-- Die Physio Sicht lehnt auch eine unbekannte Person ab, und das ist ebenfalls eine
-- Ablehnung mit Zeile: sonst waere die Id ein Orakel.
SELECT set_config('response.status', '', true);
SELECT app._t_jwt20('d2000000-0000-0000-0000-000000000003', 'physio');
SELECT is((SELECT public.rpc_body_map_region_reports('d1000000-0000-0000-0000-00000000dead')),
  app._t_body20('FORBIDDEN: daily_checkins.body_map'),
  'Physio mit unbekannter Id: dieselbe Antwort, kein Orakel');
SELECT ok((SELECT count(*) FROM app.access_denials
            WHERE actor_role = 'physio' AND resource = 'daily_checkins.body_map') = 1,
  'Auch diese Ablehnung steht im Protokoll');

-- ---------------------------------------------------------------------------
-- 6. Tueren 4 und 5: die Figur, ohne Claims (4)
-- ---------------------------------------------------------------------------
-- Ohne bestaetigtes Team schreibt log_denial bewusst keine Zeile (09_rpcs.sql,
-- team_id ist NOT NULL). Die Antwort ist trotzdem die des Vertrags, die Tuer bleibt zu.
SELECT set_config('request.jwt.claims', NULL, true);
SELECT set_config('response.status', '', true);
SELECT is((SELECT public.rpc_my_body_map_figure()),
  app._t_body20('FORBIDDEN: persons.body_map_figure'),
  'Ohne Claims: Lese Tuer der Figur antwortet mit dem Fehlerobjekt');
SELECT is(app._t_status20(), '403', 'Status 403');

SELECT set_config('response.status', '', true);
SELECT is((SELECT public.rpc_set_my_body_map_figure('weiblich')),
  app._t_body20('FORBIDDEN: persons.body_map_figure'),
  'Ohne Claims: Schreib Tuer der Figur antwortet mit dem Fehlerobjekt');
SELECT is(app._t_status20(), '403', 'Status 403');

-- ---------------------------------------------------------------------------
-- 7. Der Erfolgsweg bleibt, wie er war (5)
-- ---------------------------------------------------------------------------
SELECT set_config('response.status', '', true);
SELECT app._t_jwt20('d2000000-0000-0000-0000-000000000001', 'player');

SELECT ok(NOT app.is_denial((SELECT public.rpc_my_body_map_history())),
  'Spielerin: der eigene Verlauf ist keine Ablehnung');
SELECT is(app._t_status20(), '',
  'Der Erfolgsweg setzt response.status nicht');
SELECT ok(jsonb_typeof((SELECT public.rpc_submit_checkin(current_date, 450, 7, 6, 6, 4, 7, 7, 7, NULL))) = 'string',
  'rpc_submit_checkin liefert die id weiter als JSON String, so wie PostgREST sie aus einem uuid machte');
SELECT ok(((SELECT public.rpc_submit_checkin(current_date, 450, 7, 6, 6, 4, 7, 7, 7, NULL)) #>> '{}')::uuid
          = (SELECT id FROM app.daily_checkins
              WHERE person_id = 'd1000000-0000-0000-0000-000000000001' AND date = current_date),
  'Die id in der Antwort ist die id der geschriebenen Zeile');
SELECT is((SELECT count(*)::int FROM app.access_denials WHERE actor_role = 'player'),
  0, 'Ein erfolgreicher Aufruf schreibt keine Ablehnung');

-- ---------------------------------------------------------------------------
-- 8. Was weiterhin wirft (1)
-- ---------------------------------------------------------------------------
-- daily_checkins.date ruft kein log_denial, dort gibt es nichts zu retten. Der Weg
-- bleibt RAISE, ueber PostgREST sieht der Client bei beiden dasselbe.
SELECT throws_ok($$SELECT public.rpc_submit_checkin(current_date - 3)$$,
  '42501', 'FORBIDDEN: daily_checkins.date',
  'Das Datumsfenster wirft weiter, es schreibt keine Ablehnung');

DROP FUNCTION app._t_jwt20(text, text);
DROP FUNCTION app._t_body20(text);
DROP FUNCTION app._t_status20();

SELECT * FROM finish();
ROLLBACK;
