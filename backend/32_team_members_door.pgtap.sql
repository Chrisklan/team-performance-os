-- =============================================================================
-- 32_team_members_door.pgtap.sql — Web Vorlauf Physio Sicht (Bridge Punkt 33, 44, 64)
--
-- Prueft 32_team_members_door.sql: die Tuer public.rpc_list_team_members und die
-- Antwort 404 statt 500 auf "nicht gefunden".
--
-- WAS HIER NICHT GEPRUEFT WERDEN KANN: dass die Ablehnungszeile in
-- app.access_denials die Transaktion ueberlebt. Die Suite laeuft in einer
-- Transaktion und rollt zurueck (Lessons Learned, Befund F1). Diese Haelfte ist
-- im Autocommit gegen einen Klon gemessen, alter gegen neuen Code, siehe Audit
-- 2026-09-21-ap45-bodymap-verlauf Abschnitt 17.
--
-- Die Suite prueft: welche Rolle durch die Tuer kommt, dass die Ablehnung eine
-- Zeile in access_denials schreibt und das Lesen keine in access_log, welche
-- Personen und Schluessel in der Liste stehen, die Tuereigenschaften, kein
-- PUBLIC und kein anon, und die 404 Antwort.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(37);

-- -----------------------------------------------------------------------------
-- Fixtures: zwei Teams. Staff, Medizin und Admin nur in a1. In a1 ausserdem
-- eine deaktivierte Spielerin und eine, deren Rolle abgelaufen ist.
-- -----------------------------------------------------------------------------
INSERT INTO app.teams (id, name, timezone) VALUES
  ('a1000000-0000-0000-0000-000000000001','Team A1','Europe/Berlin'),
  ('a2000000-0000-0000-0000-000000000002','Team A2','Europe/Berlin');
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Coach A1','coach','c1000000-0000-0000-0000-000000000001',true),
  ('c2000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Athletik A1','athletik','c2000000-0000-0000-0000-000000000002',true),
  ('d1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Physio A1','physio','d1000000-0000-0000-0000-000000000001',true),
  ('d2000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Aerztin A1','doctor','d2000000-0000-0000-0000-000000000002',true),
  ('e1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Admin A1','admin','e1000000-0000-0000-0000-000000000001',true),
  ('b1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Zora A1','stuermerin','b1000000-0000-0000-0000-000000000001',true),
  ('b1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Anna A1','abwehr','b1000000-0000-0000-0000-000000000002',true),
  ('b1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','Inaktiv A1','abwehr',NULL,false),
  ('b1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','Abgelaufen A1','tor',NULL,true),
  ('b2000000-0000-0000-0000-000000000002','a2000000-0000-0000-0000-000000000002','Spielerin A2','stuermerin','b2000000-0000-0000-0000-000000000002',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('a1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','coach',          now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','c2000000-0000-0000-0000-000000000002','athletic_coach', now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','physio',         now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','doctor',         now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','admin',          now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','player',         now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000002','player',         now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000003','player',         now() - interval '30 days', NULL),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004','player',         now() - interval '30 days', now() - interval '1 day'),
  ('a2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000002','player',         now() - interval '30 days', NULL);
-- Zwei gleichzeitig gueltige Freigaben fuer Zora: die neuere gewinnt (LATERAL LIMIT 1).
INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','limited',   'Nur Rad',  current_date - 2,'d2000000-0000-0000-0000-000000000002','doctor'),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','individual','Aufbau',   current_date,    'd2000000-0000-0000-0000-000000000002','doctor');

CREATE OR REPLACE FUNCTION app._t32_jwt(p_sub text, p_role text, p_team text DEFAULT 'a1000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;
CREATE OR REPLACE FUNCTION app._t32_ids(p jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(m->>'id' ORDER BY ord), '{}') FROM jsonb_array_elements(p->'members') WITH ORDINALITY AS t(m, ord);
$$;

-- -----------------------------------------------------------------------------
-- 1. Die Rollenmatrix ueber die Tuer in public (6)
-- -----------------------------------------------------------------------------
SELECT app._t32_jwt('c1000000-0000-0000-0000-000000000001','coach');
SELECT ok(NOT app.is_denial(public.rpc_list_team_members()), 'coach: Liste erlaubt');
SELECT app._t32_jwt('c2000000-0000-0000-0000-000000000002','athletic_coach');
SELECT ok(NOT app.is_denial(public.rpc_list_team_members()), 'athletic_coach: Liste erlaubt');
SELECT app._t32_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok(NOT app.is_denial(public.rpc_list_team_members()), 'physio: Liste erlaubt');
SELECT app._t32_jwt('d2000000-0000-0000-0000-000000000002','doctor');
SELECT ok(NOT app.is_denial(public.rpc_list_team_members()), 'doctor: Liste erlaubt');
SELECT app._t32_jwt('e1000000-0000-0000-0000-000000000001','admin');
SELECT ok(NOT app.is_denial(public.rpc_list_team_members()), 'admin: Liste erlaubt');
SELECT app._t32_jwt('b1000000-0000-0000-0000-000000000001','player');
SELECT ok(app.is_denial(public.rpc_list_team_members())
          AND public.rpc_list_team_members()->>'message' = 'FORBIDDEN: persons.list',
  'player: FORBIDDEN: persons.list');

-- -----------------------------------------------------------------------------
-- 2. Die Ablehnung ist eine Antwort mit Vertrag und 403 (4)
-- -----------------------------------------------------------------------------
SELECT set_config('response.status', '', true);
SELECT is(public.rpc_list_team_members(),
  '{"code":"42501","message":"FORBIDDEN: persons.list","details":null,"hint":null}'::jsonb,
  'player: Vertrag vollstaendig, code 42501, details und hint null');
SELECT is(current_setting('response.status', true), '403', 'player: die Tuer setzt HTTP 403');
-- Regel 5: ohne team_id Claim keine Tuer, auch fuer Medizin.
SELECT set_config('request.jwt.claims',
  '{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated","app_role":"physio"}', true);
SELECT ok(app.is_denial(public.rpc_list_team_members()), 'physio ohne team_id Claim: FORBIDDEN (Regel 5)');
-- Fremdes Team im Claim: die Physio ist dort nicht bestaetigt.
SELECT app._t32_jwt('d1000000-0000-0000-0000-000000000001','physio','a2000000-0000-0000-0000-000000000002');
SELECT ok(app.is_denial(public.rpc_list_team_members()), 'physio mit fremdem team_id Claim: FORBIDDEN');

-- -----------------------------------------------------------------------------
-- 3. Protokoll: Ablehnung schreibt eine Zeile, Lesen der Liste keine (4)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _c32 AS
  SELECT (SELECT count(*) FROM app.access_denials) AS deny, (SELECT count(*) FROM app.access_log) AS log;
SELECT app._t32_jwt('b1000000-0000-0000-0000-000000000001','player');
SELECT app.rpc_list_team_members();
SELECT is((SELECT count(*) FROM app.access_denials) - (SELECT deny FROM _c32), 1::bigint,
  'Ablehnung: genau eine Zeile in access_denials');
SELECT is((SELECT resource FROM app.access_denials ORDER BY occurred_at DESC, id DESC LIMIT 1), 'persons.list',
  'Ablehnung: die Zeile nennt persons.list');
UPDATE _c32 SET deny = (SELECT count(*) FROM app.access_denials), log = (SELECT count(*) FROM app.access_log);
SELECT app._t32_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT app.rpc_list_team_members();
SELECT is((SELECT count(*) FROM app.access_log) - (SELECT log FROM _c32), 0::bigint,
  'Lesen der Liste: keine access_log Zeile (Zugriffsuebersicht ohne Rauschen)');
SELECT is((SELECT count(*) FROM app.access_denials) - (SELECT deny FROM _c32), 0::bigint,
  'Lesen der Liste: keine access_denials Zeile');

-- -----------------------------------------------------------------------------
-- 4. Wer in der Liste steht (8)
-- -----------------------------------------------------------------------------
SELECT app._t32_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT is(app._t32_ids(public.rpc_list_team_members()),
  ARRAY['b1000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001'],
  'physio: genau die zwei aktiven Spielerinnen aus a1, nach Name sortiert (Anna vor Zora)');
SELECT ok(NOT ('c1000000-0000-0000-0000-000000000001' = ANY(app._t32_ids(public.rpc_list_team_members()))),
  'kein Trainer in der Liste (die Detail-Tueren liessen ihn nicht durch)');
SELECT ok(NOT ('d1000000-0000-0000-0000-000000000001' = ANY(app._t32_ids(public.rpc_list_team_members()))),
  'keine Physio in der Liste');
SELECT ok(NOT ('b1000000-0000-0000-0000-000000000003' = ANY(app._t32_ids(public.rpc_list_team_members()))),
  'keine deaktivierte Spielerin in der Liste');
SELECT ok(NOT ('b1000000-0000-0000-0000-000000000004' = ANY(app._t32_ids(public.rpc_list_team_members()))),
  'keine Spielerin mit abgelaufener Rolle in der Liste');
SELECT ok(NOT ('b2000000-0000-0000-0000-000000000002' = ANY(app._t32_ids(public.rpc_list_team_members()))),
  'Silo: keine Spielerin aus a2 in der Liste von a1');
SELECT app._t32_jwt('c1000000-0000-0000-0000-000000000001','coach');
SELECT is(app._t32_ids(public.rpc_list_team_members()),
  ARRAY['b1000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001'],
  'coach: dieselbe Liste wie die Physio');
-- Jede Person der Liste kommt durch die Detail-Tuer: Liste und Detail laufen nicht auseinander.
SELECT app._t32_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT is((SELECT count(*) FROM jsonb_array_elements(public.rpc_list_team_members()->'members') m
            WHERE NOT app.auth_target_is_team_player((m->>'id')::uuid)), 0::bigint,
  'jede Person der Liste besteht app.auth_target_is_team_player');

-- -----------------------------------------------------------------------------
-- 5. Was je Person in der Liste steht (4)
-- -----------------------------------------------------------------------------
SELECT is((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(public.rpc_list_team_members()->'members'->0) k),
  ARRAY['clearance_status','display_name','id','person_position'],
  'genau vier Schluessel je Person, kein set_by, kein load_note, keine Gesundheitsdaten');
SELECT is((SELECT m->>'clearance_status' FROM jsonb_array_elements(public.rpc_list_team_members()->'members') m
            WHERE m->>'id' = 'b1000000-0000-0000-0000-000000000001'), 'individual',
  'zwei gueltige Freigaben: die neuere gewinnt, dieselbe Regel wie rpc_get_clearance');
SELECT is((SELECT count(*) FROM jsonb_array_elements(public.rpc_list_team_members()->'members') m
            WHERE m->>'id' = 'b1000000-0000-0000-0000-000000000001'), 1::bigint,
  'zwei gueltige Freigaben ergeben genau eine Zeile');
SELECT is((SELECT m->>'clearance_status' FROM jsonb_array_elements(public.rpc_list_team_members()->'members') m
            WHERE m->>'id' = 'b1000000-0000-0000-0000-000000000002'), 'full',
  'ohne Freigabezeile: full');

-- -----------------------------------------------------------------------------
-- 6. Tuereigenschaften, kein PUBLIC, kein anon (8)
-- -----------------------------------------------------------------------------
SELECT ok(NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.rpc_list_team_members()'::regprocedure),
  'Tuer ist SECURITY INVOKER (Befund N9)');
SELECT is((SELECT provolatile FROM pg_proc WHERE oid = 'public.rpc_list_team_members()'::regprocedure), 'v'::"char",
  'Tuer ist VOLATILE (Muster D Regel 1)');
SELECT is((SELECT provolatile FROM pg_proc WHERE oid = 'app.rpc_list_team_members()'::regprocedure), 'v'::"char",
  'app Funktion ist VOLATILE, sonst scheitert das Schreiben der Ablehnung READ ONLY (F15)');
SELECT ok((SELECT proconfig FROM pg_proc WHERE oid = 'public.rpc_list_team_members()'::regprocedure) @> ARRAY['search_path=""'],
  'Tuer hat SET search_path = leer');
SELECT is((SELECT count(*)::int FROM pg_proc p, aclexplode(p.proacl) a
           WHERE p.oid IN ('public.rpc_list_team_members()'::regprocedure, 'app.rpc_list_team_members()'::regprocedure)
             AND a.grantee = 0), 0,
  'PUBLIC hat weder auf der Tuer noch auf der app Funktion ein Recht');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_list_team_members()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'app.rpc_list_team_members()', 'EXECUTE'),
  'anon hat kein EXECUTE, weder Tuer noch app Funktion');
SELECT ok(has_function_privilege('authenticated', 'public.rpc_list_team_members()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'app.rpc_list_team_members()', 'EXECUTE'),
  'authenticated hat EXECUTE auf beiden, das Recht kam mit der Tuer (Punkt 55)');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_shred_person(uuid)', 'EXECUTE'),
  'rpc_shred_person bleibt zu, sie bekommt keine Tuer');

-- -----------------------------------------------------------------------------
-- 7. "nicht gefunden" ist 404, nicht 500 (Punkt 64) (3)
-- -----------------------------------------------------------------------------
SELECT set_config('response.status', '', true);
SELECT is(public.rpc_review_deviation('f9999999-0000-0000-0000-000000000009', 'release'),
  '{"code":"P0002","message":"NOT_FOUND: load_deviations","details":null,"hint":null}'::jsonb,
  'unbekannte Abweichung: Antwortobjekt mit code P0002 statt Ausnahme');
SELECT is(current_setting('response.status', true), '404', 'unbekannte Abweichung: HTTP 404');
-- Nur P0002 wird gefangen. Eine ungueltige Eingabe bleibt eine Ausnahme (Regel 3).
SELECT throws_ok($$SELECT public.rpc_review_deviation('f9999999-0000-0000-0000-000000000009', 'loeschen')$$,
  '22023', 'INVALID: load_deviations.decision',
  'ungueltige Entscheidung: 22023 laeuft unveraendert durch, die Tuer faengt nur P0002');

SELECT * FROM finish();
ROLLBACK;
