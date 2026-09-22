-- =============================================================================
-- 21_access_log_revoke.pgtap.sql — Rechteentzug auf app.access_log (AP-45e)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 10_auth_hook.sql,
-- 21_access_log_revoke.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Geprueft wird: authenticated darf nicht mehr per INSERT in app.access_log
-- schreiben, die Policy access_log_insert_definer ist weg, die Policy
-- access_log_select_self bleibt, RLS bleibt an und erzwungen. Der DEFINER Weg
-- (stellvertretend app.rpc_get_clearance) schreibt weiter, und
-- app.rpc_get_my_access_log liest die Zeile weiter. Eine Mutation stellt alle
-- drei entzogenen Schutzschichten wieder her und zeigt, dass der Test es faengt.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(13);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('21212121-2121-2121-2121-212121212121', 'Entzug Kader', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id) VALUES
  ('e1000000-0000-0000-0000-000000000001', '21212121-2121-2121-2121-212121212121', 'Spielerin A', 'e2000000-0000-0000-0000-000000000001'),
  ('e1000000-0000-0000-0000-000000000002', '21212121-2121-2121-2121-212121212121', 'Physio',      'e2000000-0000-0000-0000-000000000002');

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('21212121-2121-2121-2121-212121212121', 'e1000000-0000-0000-0000-000000000001', 'player', now() - interval '1 day'),
  ('21212121-2121-2121-2121-212121212121', 'e1000000-0000-0000-0000-000000000002', 'physio', now() - interval '1 day');

CREATE FUNCTION app._t_jwt21(p_sub text, p_role text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '21212121-2121-2121-2121-212121212121')::text,
    true);
$$;

-- ---------------------------------------------------------------------------
-- 1. Das Recht und die Policy sind weg (1-3)
-- ---------------------------------------------------------------------------
SELECT is(has_table_privilege('authenticated', 'app.access_log', 'INSERT'), false,
  'authenticated hat kein INSERT mehr auf app.access_log');

SELECT is((SELECT count(*)::int FROM pg_policies
            WHERE schemaname = 'app' AND tablename = 'access_log'
              AND policyname = 'access_log_insert_definer'), 0,
  'die Policy access_log_insert_definer existiert nicht mehr');

SELECT is((SELECT count(*)::int FROM pg_policies
            WHERE schemaname = 'app' AND tablename = 'access_log'
              AND policyname = 'access_log_select_self'), 1,
  'die Policy access_log_select_self bleibt unangetastet');

-- ---------------------------------------------------------------------------
-- 2. RLS bleibt an und erzwungen, auch fuer den Tabelleneigentuemer (4-5)
-- ---------------------------------------------------------------------------
SELECT is((SELECT relrowsecurity FROM pg_class
            WHERE oid = 'app.access_log'::regclass), true,
  'RLS ist weiter aktiv auf app.access_log');
SELECT is((SELECT relforcerowsecurity FROM pg_class
            WHERE oid = 'app.access_log'::regclass), true,
  'RLS ist weiter erzwungen (FORCE), auch fuer den Eigentuemer');

-- ---------------------------------------------------------------------------
-- 3. Ein direkter INSERT als authenticated scheitert jetzt am Tabellenrecht,
--    nicht mehr erst an der Sequenz (6)
-- ---------------------------------------------------------------------------
SELECT app._t_jwt21('e2000000-0000-0000-0000-000000000001', 'player');
SET ROLE authenticated;
SELECT throws_ok(
  $$INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
    VALUES ('21212121-2121-2121-2121-212121212121', 'e1000000-0000-0000-0000-000000000001',
            'e1000000-0000-0000-0000-000000000001', 'player', 'forged.direct', 'read')$$,
  '42501', NULL,
  'direkter INSERT als authenticated scheitert am fehlenden Tabellenrecht'
);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4. Der DEFINER Weg schreibt weiter, stellvertretend fuer alle sechs
--    Funktionen (app.rpc_get_clearance, app.rpc_readiness_full,
--    app.rpc_check_ins_medical, app.rpc_set_clearance,
--    app.rpc_export_my_data, app.rpc_body_map_region_reports): keine traegt
--    ein eigenes OWNER TO, alle schreiben also mit den Rechten der Rolle, die
--    diese Migration ausfuehrt, nicht mit denen von authenticated (7-9)
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM app.access_log
            WHERE team_id = '21212121-2121-2121-2121-212121212121'), 0,
  'access_log ist vor dem Definer Aufruf leer fuer diesen Kader');

SELECT app._t_jwt21('e2000000-0000-0000-0000-000000000002', 'physio');
SET ROLE authenticated;
SELECT lives_ok(
  $$SELECT app.rpc_get_clearance('e1000000-0000-0000-0000-000000000001')$$,
  'app.rpc_get_clearance (Definer Weg) laeuft trotz Entzug weiter'
);
RESET ROLE;

SELECT is((SELECT count(*)::int FROM app.access_log
            WHERE team_id = '21212121-2121-2121-2121-212121212121'
              AND subject_id = 'e1000000-0000-0000-0000-000000000001'
              AND resource = 'medical_clearances'), 1,
  'der Definer Weg hat trotz Entzug eine Zeile geschrieben');

-- ---------------------------------------------------------------------------
-- 5. rpc_get_my_access_log liest die Zeile weiter (10)
-- ---------------------------------------------------------------------------
SELECT app._t_jwt21('e2000000-0000-0000-0000-000000000001', 'player');
SET ROLE authenticated;
SELECT is((SELECT count(*)::int FROM app.rpc_get_my_access_log(NULL, NULL)
            WHERE resource = 'medical_clearances'), 1,
  'die Spielerin liest ihre eigene Zeile ueber rpc_get_my_access_log weiter'
);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6. Mutation: alle drei zurueckgenommenen Schutzschichten wieder her, dann
--    faengt der erste Test es (11-13). Drei Schichten, weil eine einzelne
--    nicht reicht, um zu zeigen, was diese Migration tatsaechlich abbaut:
--    das Tabellenrecht allein scheitert an der Sequenz (F4), Tabellenrecht
--    plus Sequenz allein scheitert an der fehlenden INSERT Policy (RLS
--    FORCE verweigert ohne passende Policy). Erst alle drei zusammen (der
--    Zustand vor AP-45e) oeffnen den direkten INSERT wieder.
-- ---------------------------------------------------------------------------
GRANT INSERT ON app.access_log TO authenticated;
GRANT USAGE ON SEQUENCE app.access_log_id_seq TO authenticated;
CREATE POLICY access_log_insert_definer ON app.access_log
  FOR INSERT TO authenticated
  WITH CHECK (team_id = app.auth_team_id());
SELECT is(has_table_privilege('authenticated', 'app.access_log', 'INSERT'), true,
  'Mutation sichtbar: mit einem erneuten GRANT hat authenticated wieder INSERT');
SELECT app._t_jwt21('e2000000-0000-0000-0000-000000000001', 'player');
SET ROLE authenticated;
SELECT lives_ok(
  $$INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action)
    VALUES ('21212121-2121-2121-2121-212121212121', 'e1000000-0000-0000-0000-000000000001',
            'e1000000-0000-0000-0000-000000000001', 'player', 'forged.direct', 'read')$$,
  'Mutation sichtbar: mit allen drei Schichten zurueck laeuft der direkte INSERT wieder durch'
);
RESET ROLE;
DROP POLICY access_log_insert_definer ON app.access_log;
REVOKE USAGE ON SEQUENCE app.access_log_id_seq FROM authenticated;
REVOKE INSERT ON app.access_log FROM authenticated;
SELECT is(has_table_privilege('authenticated', 'app.access_log', 'INSERT'), false,
  'nach dem Zuruecknehmen der Mutation ist der Ausgangszustand wieder her'
);

SELECT * FROM finish();
ROLLBACK;
