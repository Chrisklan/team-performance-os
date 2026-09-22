-- =============================================================================
-- 26_app_execute_revoke.pgtap.sql — die acht Funktionen ohne Tuer sind fuer
-- authenticated zu (Punkt 55, Befund N5)
-- Voraussetzung: 09_rpcs.sql, 14_shred_person.sql, 20_denial_answer.sql,
-- 26_app_execute_revoke.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Die Suite prueft Rechte, keine Rumpfe. Sie faengt den Tag, an dem jemand eine
-- der acht mit GRANT EXECUTE ... TO authenticated wieder oeffnet, ohne ihr eine
-- Tuer zu bauen. Baut AP-47a eine Tuer, gehoert der betreffende Name aus der
-- Liste hier heraus und in die Positivkontrolle darunter.
--
-- Die Positivkontrolle ist der wichtigere Teil: ein "acht mal false" allein
-- bewiese nur, dass der Aufbau nicht traegt. Die sechs Funktionen MIT Tuer
-- muessen ihr EXECUTE behalten, sonst faellt jede Tuer in public mit um, denn
-- sie sind SECURITY INVOKER.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(19);

-- ---------------------------------------------------------------------------
-- 1. Die acht sind zu (8)
-- ---------------------------------------------------------------------------
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_list_team_members()', 'EXECUTE'),
  'rpc_list_team_members: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_check_ins_medical(date, date)', 'EXECUTE'),
  'rpc_check_ins_medical: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_readiness_full(uuid, date, date)', 'EXECUTE'),
  'rpc_readiness_full: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_release_deviation(uuid, text)', 'EXECUTE'),
  'rpc_release_deviation: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_get_clearance(uuid)', 'EXECUTE'),
  'rpc_get_clearance: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_set_clearance(uuid, app.app_clearance, text, date, date)', 'EXECUTE'),
  'rpc_set_clearance: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_propose_clearance(uuid, app.app_clearance, text)', 'EXECUTE'),
  'rpc_propose_clearance: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_shred_person(uuid)', 'EXECUTE'),
  'rpc_shred_person: kein EXECUTE fuer authenticated');

-- ---------------------------------------------------------------------------
-- 2. Und niemand erbt es ueber PUBLIC (2)
-- ---------------------------------------------------------------------------
-- has_function_privilege('anon', ...) allein bestuende auch mit einer Default ACL,
-- die authenticated und anon ueber PUBLIC bedient. Die ACL selbst lesen (AP-39b).
SELECT is((SELECT count(*)::int FROM pg_proc p, aclexplode(p.proacl) a
           WHERE p.pronamespace = 'app'::regnamespace
             AND p.proname IN ('rpc_list_team_members','rpc_check_ins_medical','rpc_readiness_full',
                               'rpc_release_deviation','rpc_get_clearance','rpc_set_clearance',
                               'rpc_propose_clearance','rpc_shred_person')
             AND a.grantee = 0),
  0, 'PUBLIC hat auf keiner der acht ein Recht, die Default ACL ist nicht im Spiel');
SELECT is((SELECT count(*)::int FROM pg_proc p
           WHERE p.pronamespace = 'app'::regnamespace
             AND p.proname IN ('rpc_list_team_members','rpc_check_ins_medical','rpc_readiness_full',
                               'rpc_release_deviation','rpc_get_clearance','rpc_set_clearance',
                               'rpc_propose_clearance','rpc_shred_person')
             AND p.proacl IS NULL),
  0, 'Keine der acht hat eine leere ACL, aus der PUBLIC das Recht erbte');

-- ---------------------------------------------------------------------------
-- 3. Positivkontrolle: die Funktionen MIT Tuer behalten ihr Recht (7)
-- ---------------------------------------------------------------------------
-- Die Tueren in public sind SECURITY INVOKER. Ohne dieses EXECUTE bricht jede von
-- ihnen im eigenen Rumpf mit 42501 ab, gemessen im Wegwerf-Klon am 2026-09-22.
SELECT ok(has_function_privilege('authenticated', 'app.rpc_my_body_map_figure()', 'EXECUTE'),
  'rpc_my_body_map_figure behaelt EXECUTE, die Tuer haengt daran');
SELECT ok(has_function_privilege('authenticated', 'app.rpc_set_my_body_map_figure(text)', 'EXECUTE'),
  'rpc_set_my_body_map_figure behaelt EXECUTE');
SELECT ok(has_function_privilege('authenticated', 'app.rpc_my_body_map_history(integer)', 'EXECUTE'),
  'rpc_my_body_map_history behaelt EXECUTE');
SELECT ok(has_function_privilege('authenticated', 'app.rpc_body_map_region_reports(uuid, integer)', 'EXECUTE'),
  'rpc_body_map_region_reports behaelt EXECUTE');
SELECT ok(has_function_privilege('authenticated', 'app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb)', 'EXECUTE'),
  'rpc_submit_checkin behaelt EXECUTE, das ist der einzige Schreibweg des Check-ins');
SELECT ok(has_function_privilege('authenticated', 'app.rpc_morning_ops()', 'EXECUTE'),
  'rpc_morning_ops behaelt EXECUTE, daran haengt das Trainer Dashboard');
-- Die Helper, ohne die kein Waechter und keine Tuer laeuft.
SELECT ok(has_function_privilege('authenticated', 'app.auth_team_id()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'app.auth_person_id()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'app.is_denial(jsonb)', 'EXECUTE'),
  'Die Helper der Tueren sind unberuehrt: auth_team_id, auth_person_id, is_denial');

-- ---------------------------------------------------------------------------
-- 4. Was nie offen war, bleibt zu (2)
-- ---------------------------------------------------------------------------
SELECT ok(NOT has_function_privilege('authenticated', 'app.log_denial(text)', 'EXECUTE')
      AND NOT has_function_privilege('authenticated', 'app.deny(text, text)', 'EXECUTE'),
  'log_denial und deny bleiben fuer authenticated zu, gerufen werden sie nur von innen');
SELECT is((SELECT count(*)::int FROM pg_proc p
           WHERE p.pronamespace = 'app'::regnamespace
             AND has_function_privilege('anon', p.oid, 'EXECUTE')
             AND p.proname LIKE 'rpc_%'),
  0, 'anon hat auf keiner rpc_ Funktion in app ein EXECUTE (AP-39b, unveraendert)');

SELECT * FROM finish();
ROLLBACK;
