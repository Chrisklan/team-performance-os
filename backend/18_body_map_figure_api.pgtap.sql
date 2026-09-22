-- =============================================================================
-- 18_body_map_figure_api.pgtap.sql — public.rpc_my_body_map_figure und
-- public.rpc_set_my_body_map_figure (AP-44c)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 10_auth_hook.sql,
-- 17_squad_figure.sql, 18_body_map_figure_api.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Die Suite prueft die Tuer, nicht die Aufloesung (das macht Suite 17): dass sie
-- nur fuer angemeldete Personen offen ist, dass sie nur die eigene Zeile beruehrt
-- und dass sie nichts zurueckgibt, was nicht Darstellung ist.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(22);

INSERT INTO app.teams (id, name, timezone, squad_type) VALUES
  ('18181818-1818-1818-1818-181818181818', 'Tuer Kader', 'Europe/Berlin', 'frauen');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('e1000000-0000-0000-0000-000000000001', '18181818-1818-1818-1818-181818181818', 'Spielerin A', 'e2000000-0000-0000-0000-000000000001', 7),
  ('e1000000-0000-0000-0000-000000000002', '18181818-1818-1818-1818-181818181818', 'Spielerin B', 'e2000000-0000-0000-0000-000000000002', 9),
  ('e1000000-0000-0000-0000-000000000003', '18181818-1818-1818-1818-181818181818', 'Trainerin',   'e2000000-0000-0000-0000-000000000003', NULL);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('18181818-1818-1818-1818-181818181818', 'e1000000-0000-0000-0000-000000000001', 'player', now() - interval '1 day'),
  ('18181818-1818-1818-1818-181818181818', 'e1000000-0000-0000-0000-000000000002', 'player', now() - interval '1 day'),
  ('18181818-1818-1818-1818-181818181818', 'e1000000-0000-0000-0000-000000000003', 'coach',  now() - interval '1 day');

CREATE FUNCTION app._t_jwt18(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '18181818-1818-1818-1818-181818181818')::text,
    true);
$$;

-- ---------------------------------------------------------------------------
-- Aufbau und Rechte
-- ---------------------------------------------------------------------------
SELECT has_function('public', 'rpc_my_body_map_figure', ARRAY[]::text[], 'Lese Tuer existiert');
SELECT has_function('public', 'rpc_set_my_body_map_figure', ARRAY['text'], 'Schreib Tuer existiert');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('rpc_my_body_map_figure', 'rpc_set_my_body_map_figure')),
  2, 'Je Name genau eine Funktion, keine Ueberladung, die PostgREST mehrdeutig machte');
SELECT is((SELECT count(*)::int FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('rpc_my_body_map_figure', 'rpc_set_my_body_map_figure')
             AND prosecdef),
  0, 'Beide Tueren sind SECURITY INVOKER');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_my_body_map_figure()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.rpc_set_my_body_map_figure(text)', 'EXECUTE'),
  'anon darf keine der beiden Tueren aufrufen');
SELECT ok(has_function_privilege('authenticated', 'public.rpc_my_body_map_figure()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_set_my_body_map_figure(text)', 'EXECUTE'),
  'authenticated darf beide Tueren aufrufen');
SELECT is((SELECT count(*)::int FROM pg_proc p, aclexplode(p.proacl) a
           WHERE p.pronamespace = 'public'::regnamespace
             AND p.proname IN ('rpc_my_body_map_figure', 'rpc_set_my_body_map_figure')
             AND a.grantee = 0),
  0, 'PUBLIC hat keine Rechte, die Default ACL ist nicht mehr im Spiel');

-- ---------------------------------------------------------------------------
-- Die eigene Figur ueber die Tuer
-- ---------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t_jwt18('e2000000-0000-0000-0000-000000000001', 'player');
SELECT is((public.rpc_my_body_map_figure() ->> 'figure'), 'weiblich',
  'Spielerin im Frauenkader bekommt ueber die Tuer ohne Zutun die weibliche Figur');
SELECT is((public.rpc_my_body_map_figure() ->> 'preference'), 'aus_dem_team',
  'Die Praeferenz steht auf der Vorgabe, es gab keine Frage im Onboarding');
SELECT is((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(public.rpc_my_body_map_figure()) k),
  ARRAY['figure', 'preference', 'squadType'],
  'Die Antwort traegt genau drei Felder, keine Person, kein Geschlecht');

SELECT is((public.rpc_set_my_body_map_figure('neutral') ->> 'figure'), 'neutral',
  'Umstellen ueber die Tuer wirkt sofort und liefert die neue Figur zurueck');
SELECT is((public.rpc_my_body_map_figure() ->> 'preference'), 'neutral',
  'Und bleibt beim naechsten Lesen stehen');
SELECT throws_ok($$SELECT public.rpc_set_my_body_map_figure('divers')$$,
  '22023', 'INVALID: persons.body_map_figure',
  'Ein Wert ausserhalb der vier wird abgelehnt');
SELECT throws_ok($$SELECT public.rpc_set_my_body_map_figure(NULL)$$,
  '23502', NULL,
  'NULL wird abgewiesen (NOT NULL der Spalte), nichts wird still auf einen Wert gesetzt');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Nur die eigene Zeile
-- ---------------------------------------------------------------------------
SELECT is((SELECT body_map_figure::text FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000001'),
  'neutral', 'Zeile der Spielerin A steht auf neutral');
SELECT is((SELECT body_map_figure::text FROM app.persons WHERE id = 'e1000000-0000-0000-0000-000000000002'),
  'aus_dem_team', 'Zeile der Spielerin B ist unberuehrt');

SET ROLE authenticated;
SELECT app._t_jwt18('e2000000-0000-0000-0000-000000000003', 'coach');
SELECT is((public.rpc_set_my_body_map_figure('maennlich') ->> 'figure'), 'maennlich',
  'Auch die Trainerin stellt nur ihre eigene Darstellung um');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM app.persons
           WHERE body_map_figure <> 'aus_dem_team'
             AND id IN ('e1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000003')),
  2, 'Es stehen genau zwei Zeilen abweichend, die beiden eigenen. B blieb, wie sie war');

-- Dasselbe noch einmal setzen erzeugt keine weitere Vollkopie der Personenzeile im audit_log.
SET ROLE authenticated;
SELECT app._t_jwt18('e2000000-0000-0000-0000-000000000001', 'player');
RESET ROLE;
SELECT set_config('tpos.audit_before', (SELECT count(*)::text FROM app.audit_log), true);
SET ROLE authenticated;
SELECT app._t_jwt18('e2000000-0000-0000-0000-000000000001', 'player');
SELECT public.rpc_set_my_body_map_figure('neutral');
RESET ROLE;
SELECT is((SELECT count(*)::text FROM app.audit_log), current_setting('tpos.audit_before'),
  'Denselben Wert erneut zu setzen laesst das audit_log unveraendert');

-- ---------------------------------------------------------------------------
-- Ohne Anmeldung
-- ---------------------------------------------------------------------------
SET ROLE anon;
SELECT throws_ok($$SELECT public.rpc_my_body_map_figure()$$, '42501', NULL, 'anon: Lesen abgewiesen');
SELECT throws_ok($$SELECT public.rpc_set_my_body_map_figure('neutral')$$, '42501', NULL, 'anon: Schreiben abgewiesen');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT public.rpc_my_body_map_figure()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: persons.body_map_figure', 'details', NULL, 'hint', NULL),
  'Ohne Claims FORBIDDEN, keine fremde Person wird geraten');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
