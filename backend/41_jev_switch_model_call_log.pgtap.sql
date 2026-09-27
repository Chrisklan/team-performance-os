-- =============================================================================
-- 41_jev_switch_model_call_log.pgtap.sql — AP-69 JEV hinter Schalter,
-- Aufrufprotokoll ohne Inhalt
--
-- Prueft backend/41_jev_switch_model_call_log.sql:
--   * Rollenmatrix app.rpc_set_module_flag nach dem Umbau: loaddeviation_
--     enabled weiterhin nur doctor, jev_squad_check_enabled nur admin (nicht
--     coach), unbekanntes Flag deny, set_by_role aus dem Claim.
--   * app.model_call_log/model_call_subjects: keine Inhaltsspalte, kein
--     Client-Zugriff, CHECKs (kein -latest, Ausloeser-Form).
--   * app.rpc_squad_check_jev_context: Nicht-Staff FORBIDDEN, fremdes Team
--     P0002, Schalter aus 55000, Entwurf leer ohne Protokoll. Kandidatenfilter
--     schliesst Spiegel, regelseitig Eskalierte, weggeklickte Hinweise (auch
--     j1), pain_max, unveroeffentlichte Abweichungen und Abweichungen bei
--     ausgeschaltetem LoadDeviation-Modul aus. Payload-Grep auf verbotene
--     Schluessel. Genau eine Protokollzeile je Aufruf, Subjects = Kandidaten,
--     Hash unabhaengig vom zufaelligen Pseudonym.
--   * app.rpc_finish_model_call: nur eigene, frische pending-Zeile.
--   * T2: kein Schreiben auf medical_clearances/readiness_scores.
--   * T6: app.rpc_shred_person erfasst model_call_subjects, model_call_log
--     (Ausloeser) und session_hint_dismissals.
-- Laeuft in einer Transaktion und rollt zurueck, die Test-DB bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(107);

-- -----------------------------------------------------------------------------
-- Fixtures (als Superuser). Entwurf/Einheit: Intensitaet 6 x 60 min = 360.
--   Q1 full, Band low,  median 280 -> h1+h2 -> reduced (regelseitig eskaliert)
--   Q3 full, Band high, median 280 -> h2 (z < 2)                -> Kandidat
--   Q4 full, Band low,  median 360 -> h1                        -> Kandidat
--   Q5 full, kein Check-in, keine Baseline -> nur h3            -> kein Kandidat
--   Q6 blocked, Band low, median 280 -> Spiegel aussetzen       -> kein Kandidat
--   Q8 limited, Band low             -> Spiegel reduziert       -> kein Kandidat
--   Q9 full, Band high, median 360, freigegebene session_load.above -> nur h4,
--      Kandidat NUR bei LoadDeviation-Modul an
--   QA full, Band high, median 360, nur pain_max freigegeben und eine
--      unveroeffentlichte Abweichung                          -> nie Kandidat
--   QB full, Band low,  median 360 -> h1, j1 weggeklickt        -> kein Kandidat
--   QC full, Band low,  median 360 -> h1 weggeklickt            -> kein Kandidat
-- -----------------------------------------------------------------------------

INSERT INTO app.teams (id, name, timezone) VALUES
  ('b1000000-0000-0000-0000-000000000001','Team B1','Europe/Berlin'),
  ('b1000000-0000-0000-0000-000000000008','Team B1b (fremd)','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('b1100000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','Coach B1',NULL,NULL,'b1100000-0000-0000-0000-000000000002',true),
  ('b1100000-0000-0000-0000-000000000003','b1000000-0000-0000-0000-000000000001','Athletik B1',NULL,NULL,'b1100000-0000-0000-0000-000000000003',true),
  ('b1100000-0000-0000-0000-000000000004','b1000000-0000-0000-0000-000000000001','Aerztin B1',NULL,NULL,'b1100000-0000-0000-0000-000000000004',true),
  ('b1100000-0000-0000-0000-000000000005','b1000000-0000-0000-0000-000000000001','Admin B1',NULL,NULL,'b1100000-0000-0000-0000-000000000005',true),
  ('b1100000-0000-0000-0000-000000000006','b1000000-0000-0000-0000-000000000001','Physio B1',NULL,NULL,'b1100000-0000-0000-0000-000000000006',true),
  ('b1100000-0000-0000-0000-000000000011','b1000000-0000-0000-0000-000000000001','Q1 Markantname','sturm',11,'b1100000-0000-0000-0000-000000000011',true),
  ('b1100000-0000-0000-0000-000000000013','b1000000-0000-0000-0000-000000000001','Q3 Markantname','abwehr',13,NULL,true),
  ('b1100000-0000-0000-0000-000000000014','b1000000-0000-0000-0000-000000000001','Q4 Markantname','abwehr',14,NULL,true),
  ('b1100000-0000-0000-0000-000000000015','b1000000-0000-0000-0000-000000000001','Q5 Markantname','tor',15,NULL,true),
  ('b1100000-0000-0000-0000-000000000016','b1000000-0000-0000-0000-000000000001','Q6 Markantname','mitte',16,NULL,true),
  ('b1100000-0000-0000-0000-000000000018','b1000000-0000-0000-0000-000000000001','Q8 Markantname','mitte',18,NULL,true),
  ('b1100000-0000-0000-0000-000000000019','b1000000-0000-0000-0000-000000000001','Q9 Markantname','mitte',19,NULL,true),
  ('b1100000-0000-0000-0000-00000000001a','b1000000-0000-0000-0000-000000000001','QA Markantname','mitte',20,NULL,true),
  ('b1100000-0000-0000-0000-00000000001b','b1000000-0000-0000-0000-000000000001','QB Markantname','mitte',21,NULL,true),
  ('b1100000-0000-0000-0000-00000000001c','b1000000-0000-0000-0000-000000000001','QC Markantname','mitte',22,NULL,true),
  ('b1100000-0000-0000-0000-000000000008','b1000000-0000-0000-0000-000000000008','Coach B1b',NULL,NULL,'b1100000-0000-0000-0000-000000000008',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id
         WHEN 'b1100000-0000-0000-0000-000000000002' THEN 'coach'
         WHEN 'b1100000-0000-0000-0000-000000000003' THEN 'athletic_coach'
         WHEN 'b1100000-0000-0000-0000-000000000004' THEN 'doctor'
         WHEN 'b1100000-0000-0000-0000-000000000005' THEN 'admin'
         WHEN 'b1100000-0000-0000-0000-000000000006' THEN 'physio'
         WHEN 'b1100000-0000-0000-0000-000000000008' THEN 'coach'
         ELSE 'player'
       END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'b11%';

CREATE OR REPLACE FUNCTION app._t41_jwt(p_sub text, p_role text, p_team text DEFAULT 'b1000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- Personen, die ein JEV-Kontext als Kandidaten fuehrt (ueber die refs).
CREATE OR REPLACE FUNCTION app._t41_cand_people(p_ctx jsonb)
RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(e ->> 'person_id' ORDER BY e ->> 'person_id'), ARRAY[]::text[])
    FROM jsonb_array_elements(p_ctx -> 'refs') e;
$$;

INSERT INTO app.medical_clearances (team_id, person_id, status, valid_from, set_by_role)
SELECT 'b1000000-0000-0000-0000-000000000001', p.id,
       CASE p.id WHEN 'b1100000-0000-0000-0000-000000000016' THEN 'blocked'
                 WHEN 'b1100000-0000-0000-0000-000000000018' THEN 'limited'
                 ELSE 'full' END::app.app_clearance,
       now() - interval '5 days', 'doctor'
  FROM app.persons p
 WHERE p.id::text LIKE 'b1100000-0000-0000-0000-00000000001%';

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at, checkin_submitted_at)
SELECT 'b1000000-0000-0000-0000-000000000001', p.id, current_date, 5, now(), now()
  FROM app.persons p
 WHERE p.id::text LIKE 'b1100000-0000-0000-0000-00000000001%'
   AND p.id <> 'b1100000-0000-0000-0000-000000000015';

INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors)
SELECT 'b1000000-0000-0000-0000-000000000001', p.id, current_date,
       CASE WHEN p.id IN ('b1100000-0000-0000-0000-000000000013','b1100000-0000-0000-0000-000000000019',
                          'b1100000-0000-0000-0000-00000000001a') THEN 8.0 ELSE 3.0 END,
       CASE WHEN p.id IN ('b1100000-0000-0000-0000-000000000013','b1100000-0000-0000-0000-000000000019',
                          'b1100000-0000-0000-0000-00000000001a') THEN 'high' ELSE 'low' END::app.app_readiness_band,
       '{"sleep_quality": 5}'::jsonb
  FROM app.persons p
 WHERE p.id::text LIKE 'b1100000-0000-0000-0000-00000000001%'
   AND p.id <> 'b1100000-0000-0000-0000-000000000015';

INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status)
SELECT 'b1000000-0000-0000-0000-000000000001', p.id, 'session_load', current_date, 20,
       CASE WHEN p.id IN ('b1100000-0000-0000-0000-000000000011','b1100000-0000-0000-0000-000000000013',
                          'b1100000-0000-0000-0000-000000000016') THEN 280 ELSE 360 END,
       60, 'neutral', 'ok'
  FROM app.persons p
 WHERE p.id::text LIKE 'b1100000-0000-0000-0000-00000000001%'
   AND p.id <> 'b1100000-0000-0000-0000-000000000015';

INSERT INTO app.load_deviations (team_id, person_id, metric, date, deviation, state, statement_key) VALUES
  ('b1000000-0000-0000-0000-000000000001','b1100000-0000-0000-0000-000000000019','session_load',  current_date - 1, 40,'released',  'session_load.above'),
  ('b1000000-0000-0000-0000-000000000001','b1100000-0000-0000-0000-00000000001a','pain_max',      current_date - 1, 50,'released',  'pain_max.above'),
  ('b1000000-0000-0000-0000-000000000001','b1100000-0000-0000-0000-00000000001a','sleep_quality', current_date - 1,-30,'unreviewed','sleep_quality.below');

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity, created_by) VALUES
  ('b1200000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001', current_date, 60, 'field', 6, 'b1100000-0000-0000-0000-000000000002'),
  ('b1200000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001', current_date + 1, 60, 'gym', 6, 'b1100000-0000-0000-0000-000000000002'),
  ('b1200000-0000-0000-0000-000000000008','b1000000-0000-0000-0000-000000000008', current_date, 60, 'field', 6, 'b1100000-0000-0000-0000-000000000008');

-- -----------------------------------------------------------------------------
-- 1. Struktur: model_call_log/model_call_subjects ohne Inhalt, ohne Client
-- -----------------------------------------------------------------------------
SELECT has_table('app', 'model_call_log', 'app.model_call_log existiert');
SELECT has_table('app', 'model_call_subjects', 'app.model_call_subjects existiert');
SELECT hasnt_column('app', 'model_call_log', 'prompt',   'model_call_log hat keine Spalte prompt');
SELECT hasnt_column('app', 'model_call_log', 'response', 'model_call_log hat keine Spalte response');
SELECT hasnt_column('app', 'model_call_log', 'payload',  'model_call_log hat keine Spalte payload');
SELECT hasnt_column('app', 'model_call_log', 'request',  'model_call_log hat keine Spalte request');
SELECT hasnt_column('app', 'model_call_log', 'answer',   'model_call_log hat keine Spalte answer');
SELECT hasnt_column('app', 'model_call_log', 'state',    'model_call_log hat keine Spalte state');
SELECT is((SELECT count(*)::int FROM information_schema.columns
            WHERE table_schema = 'app' AND table_name IN ('model_call_log','model_call_subjects')
              AND data_type IN ('json','jsonb','text[]','bytea')), 0,
  'keine json/jsonb/bytea/Array-Spalte, in der Inhalt landen koennte');
SELECT is((SELECT count(*)::int FROM information_schema.columns
            WHERE table_schema = 'app' AND table_name = 'model_call_log'
              AND data_type = 'text'
              AND column_name NOT IN ('purpose','actor_kind','job_key','provider','model','rule_version','input_hash','result_class')), 0,
  'jede text-Spalte in model_call_log ist bekannt und an eine Werteliste oder den Hash gebunden');
SELECT ok(NOT has_table_privilege('authenticated', 'app.model_call_log', 'SELECT'), 'authenticated liest model_call_log nicht');
SELECT ok(NOT has_table_privilege('authenticated', 'app.model_call_log', 'INSERT'), 'authenticated schreibt model_call_log nicht');
SELECT ok(NOT has_table_privilege('authenticated', 'app.model_call_subjects', 'SELECT'), 'authenticated liest model_call_subjects nicht');
SELECT ok(NOT has_table_privilege('anon', 'app.model_call_log', 'SELECT'), 'anon liest model_call_log nicht');
SELECT ok(NOT has_sequence_privilege('authenticated', 'app.model_call_log_id_seq', 'USAGE'), 'authenticated hat kein Recht auf die Sequenz');
SELECT ok((SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'app.model_call_log'::regclass),
  'model_call_log: RLS an und erzwungen');
SELECT throws_ok(
  $$INSERT INTO app.model_call_log (team_id, purpose, actor_kind, job_key, provider, model, rule_version, input_hash, subject_count)
    VALUES ('b1000000-0000-0000-0000-000000000001','ap69_squad_check','job','t','openrouter','typesafe/jev-latest','v1','x',1)$$,
  '23514', NULL, 'CHECK: ein Modell mit latest wird abgelehnt');
SELECT throws_ok(
  $$INSERT INTO app.model_call_log (team_id, purpose, actor_kind, provider, model, rule_version, input_hash, subject_count)
    VALUES ('b1000000-0000-0000-0000-000000000001','ap69_squad_check','person','openrouter','typesafe/jev-1.13','v1','x',1)$$,
  '23514', NULL, 'CHECK: person ohne actor_id/actor_role wird abgelehnt');
SELECT throws_ok(
  $$INSERT INTO app.model_call_log (team_id, purpose, actor_kind, job_key, provider, model, rule_version, input_hash, subject_count)
    VALUES ('b1000000-0000-0000-0000-000000000001','ap99_other','job','t','openrouter','typesafe/jev-1.13','v1','x',1)$$,
  '23514', NULL, 'CHECK: unbekannter Zweck wird abgelehnt');
SELECT ok(NOT has_function_privilege('authenticated', 'app._module_flag_setters(text)', 'EXECUTE'),
  'authenticated darf app._module_flag_setters nicht direkt ausfuehren');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_squad_check_jev_context(uuid,smallint,smallint)', 'EXECUTE'),
  'Tuer rpc_squad_check_jev_context nicht fuer anon');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_finish_model_call(bigint,text,integer)', 'EXECUTE'),
  'Tuer rpc_finish_model_call nicht fuer anon');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_shred_person(uuid)', 'EXECUTE'),
  'rpc_shred_person bleibt ohne EXECUTE fuer authenticated (Punkt 55)');

-- -----------------------------------------------------------------------------
-- 2. Rollenmatrix app.rpc_set_module_flag
-- -----------------------------------------------------------------------------
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(NOT app.rpc_get_module_flag('jev_squad_check_enabled'), 'JEV-Schalter steht ohne Zeile auf aus');
SELECT ok(app.is_denial(app.rpc_set_module_flag('jev_squad_check_enabled', true)), 'coach darf den JEV-Schalter NICHT setzen');
SELECT ok(app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)), 'coach darf das LoadDeviation-Flag nicht setzen');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000003', 'athletic_coach');
SELECT ok(app.is_denial(app.rpc_set_module_flag('jev_squad_check_enabled', true)), 'athletic_coach darf den JEV-Schalter nicht setzen');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(app.is_denial(app.rpc_set_module_flag('jev_squad_check_enabled', true)), 'doctor darf den JEV-Schalter nicht setzen');
SELECT ok(app.is_denial(app.rpc_set_module_flag('irgendwas_enabled', true)), 'doctor: unbekanntes Flag deny');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000006', 'physio');
SELECT ok(app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)), 'physio darf das LoadDeviation-Flag nicht setzen');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000011', 'player');
SELECT ok(app.is_denial(app.rpc_set_module_flag('jev_squad_check_enabled', true)), 'player darf den JEV-Schalter nicht setzen');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000005', 'admin');
SELECT ok(app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)), 'admin darf das LoadDeviation-Flag weiterhin nicht setzen');
SELECT ok(app.is_denial(app.rpc_set_module_flag('irgendwas_enabled', true)), 'admin: unbekanntes Flag deny');
SELECT is((SELECT count(*)::int FROM app.module_flags WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 0,
  'keine der abgelehnten Anfragen hat eine Zeile geschrieben');
SELECT throws_ok($$ SELECT app.rpc_set_module_flag('jev_squad_check_enabled', NULL) $$, '22023', NULL,
  'admin: enabled NULL ist ein Eingabefehler');

-- -----------------------------------------------------------------------------
-- 3. JEV-Kontext: Rollen, Team, Schalter, Entwurf
-- -----------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SELECT ok(app.is_denial(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint)),
  'ohne bestaetigte Claims: deny');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000011', 'player');
SELECT ok(app.is_denial(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint)),
  'player: FORBIDDEN');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000005', 'admin');
SELECT ok(app.is_denial(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint)),
  'admin: FORBIDDEN (nur Staff)');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(app.is_denial(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint)),
  'doctor: FORBIDDEN');

SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok($$ SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000008', 60::smallint, 6::smallint) $$,
  'P0002', NULL, 'fremdes Team: P0002');
SELECT throws_ok($$ SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint) $$,
  '55000', 'MODULE_DISABLED', 'Schalter aus: 55000 MODULE_DISABLED');
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 0,
  'Schalter aus: keine Protokollzeile');

-- Wegklicks fuer QB (j1) und QC (h1), noch vor dem Einschalten.
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-00000000001b', 'j1')),
  'coach klickt j1 fuer QB weg');
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-00000000001c', 'h1')),
  'coach klickt h1 fuer QC weg');

SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000005', 'admin');
SELECT ok(NOT app.is_denial(app.rpc_set_module_flag('jev_squad_check_enabled', true)), 'admin setzt den JEV-Schalter');
SELECT is((SELECT set_by_role::text FROM app.module_flags
            WHERE team_id = 'b1000000-0000-0000-0000-000000000001' AND flag = 'jev_squad_check_enabled'),
  'admin', 'set_by_role kommt aus dem Claim (admin), nicht fest doctor');
SELECT is((SELECT set_by FROM app.module_flags
            WHERE team_id = 'b1000000-0000-0000-0000-000000000001' AND flag = 'jev_squad_check_enabled'),
  'b1100000-0000-0000-0000-000000000005'::uuid, 'set_by ist die Admin-Person');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(NOT app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', false)), 'doctor setzt das LoadDeviation-Flag weiterhin (hier aus)');
SELECT is((SELECT set_by_role::text FROM app.module_flags
            WHERE team_id = 'b1000000-0000-0000-0000-000000000001' AND flag = 'loaddeviation_enabled'),
  'doctor', 'LoadDeviation-Flag: set_by_role doctor');

SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(app.rpc_get_module_flag('jev_squad_check_enabled'), 'coach liest den JEV-Schalter als an');

SELECT is(app.rpc_squad_check_jev_context(NULL, 60::smallint, 6::smallint),
  '{"refs": [], "call_id": null, "candidates": []}'::jsonb, 'Entwurf ohne session_id: leer');
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 0,
  'Entwurf: keine Protokollzeile');
SELECT throws_ok($$ SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 0::smallint) $$,
  '22023', NULL, 'Intensitaet 0: 22023');

-- -----------------------------------------------------------------------------
-- 4. Kandidatenfilter und Payload, LoadDeviation-Modul AUS
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE t41a AS
  SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint) AS c;

SELECT is((SELECT app._t41_cand_people(c) FROM t41a),
  ARRAY['b1100000-0000-0000-0000-000000000013','b1100000-0000-0000-0000-000000000014'],
  'Modul aus: nur Q3 (h2 < 2) und Q4 (h1). Ausgeschlossen: Q1 eskaliert, Q5 nur h3, Q6/Q8 Spiegel, Q9 h4 ohne Modul, QA pain_max/unveroeffentlicht, QB j1, QC h1 weggeklickt');
SELECT is((SELECT jsonb_array_length(c -> 'candidates') FROM t41a), 2, 'zwei Kandidaten im Kontext');
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 1,
  'genau eine Protokollzeile fuer den Aufruf');
SELECT is((SELECT array_agg(person_id::text ORDER BY person_id) FROM app.model_call_subjects WHERE call_id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  (SELECT app._t41_cand_people(c) FROM t41a), 'model_call_subjects = Kandidatenmenge');
SELECT is((SELECT row(purpose, actor_kind, actor_id::text, actor_role::text, provider, model, rule_version, result_class, subject_count::int, context_ref::text)::text
             FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  row('ap69_squad_check','person','b1100000-0000-0000-0000-000000000002','coach','openrouter','typesafe/jev-1.13','v1','pending',2,'b1200000-0000-0000-0000-000000000001')::text,
  'Protokollzeile: Zweck, Ausloeser, Anbieter, Modell, Regelversion, pending, Anzahl, Einheit');
SELECT ok((SELECT input_hash ~ '^[0-9a-f]{64}$' FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  'input_hash ist ein sha256-Hexwert');
SELECT ok((SELECT finished_at IS NULL AND latency_ms IS NULL FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  'pending-Zeile ohne finished_at/latency_ms');
SELECT is((SELECT c ->> 'model' FROM t41a), 'typesafe/jev-1.13', 'Kontext nennt das protokollierte Modell');
SELECT is((SELECT c -> 'session' FROM t41a), '{"duration_min": 60, "session_type": "field", "planned_intensity": 6}'::jsonb,
  'Session-Kontext nur Dauer, Intensitaet, Typ');

-- Payload-Grep: verbotene Schluessel und Werte tauchen in candidates/session nicht auf.
SELECT is((SELECT count(*)::int FROM t41a,
             unnest(ARRAY['score_total','factors','pain','body_map','display_name','jersey','shirt','clearance',
                          'person_id','checkin','position','Markantname','b1100000']) AS forbidden
            WHERE (c -> 'candidates')::text ILIKE '%' || forbidden || '%'
               OR (c -> 'session')::text ILIKE '%' || forbidden || '%'), 0,
  'Payload-Grep: kein verbotener Schluessel oder Wert in candidates/session');
SELECT is((SELECT count(*)::int FROM t41a, jsonb_array_elements(c -> 'candidates') e
            WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e) k)
                  <> ARRAY['band','planned_load_vs_own_norm','ref','released_deviations_7d']), 0,
  'jeder Kandidat traegt genau ref, band, planned_load_vs_own_norm, released_deviations_7d');
SELECT is((SELECT count(*)::int FROM t41a, jsonb_array_elements(c -> 'candidates') e
            WHERE e ->> 'planned_load_vs_own_norm' NOT IN ('far_above','above','normal','below','no_norm')), 0,
  'Laststufe als Klasse, nie eine Zahl');
SELECT is((SELECT count(*)::int FROM t41a, jsonb_array_elements(c -> 'candidates') e WHERE e ->> 'ref' !~ '^A[0-9]{2,}$'), 0,
  'Pseudonym in der Form A01, A02');
SELECT is((SELECT count(DISTINCT e ->> 'ref')::int FROM t41a, jsonb_array_elements(c -> 'candidates') e), 2,
  'Pseudonyme eindeutig');
SELECT is((SELECT (SELECT array_agg(e ->> 'ref' ORDER BY e ->> 'ref') FROM jsonb_array_elements(c -> 'candidates') e)
             = (SELECT array_agg(e ->> 'ref' ORDER BY e ->> 'ref') FROM jsonb_array_elements(c -> 'refs') e) FROM t41a), true,
  'refs uebersetzt genau die Pseudonyme der Kandidaten zurueck');

-- Hash: dieselben Eingaben, anderes Zufallspseudonym -> derselbe Hash.
CREATE TEMP TABLE t41b AS
  SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint) AS c;
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 2,
  'zweiter Aufruf: genau eine weitere Protokollzeile');
SELECT is((SELECT input_hash FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41b)),
          (SELECT input_hash FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  'input_hash haengt nicht vom Pseudonym ab (ref nicht im Hash)');
CREATE TEMP TABLE t41c AS
  SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 65::smallint, 6::smallint) AS c;
SELECT isnt((SELECT input_hash FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41c)),
            (SELECT input_hash FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  'andere Eingaben (Dauer 65, gleiche Kandidaten) -> anderer Hash');

-- -----------------------------------------------------------------------------
-- 5. Kandidatenfilter mit LoadDeviation-Modul AN
-- -----------------------------------------------------------------------------
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(NOT app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)), 'doctor schaltet LoadDeviation ein');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000002', 'coach');
CREATE TEMP TABLE t41d AS
  SELECT app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint) AS c;
SELECT is((SELECT app._t41_cand_people(c) FROM t41d),
  ARRAY['b1100000-0000-0000-0000-000000000013','b1100000-0000-0000-0000-000000000014','b1100000-0000-0000-0000-000000000019'],
  'Modul an: Q9 kommt ueber h4 dazu, QA (nur pain_max/unveroeffentlicht) weiterhin nicht');
SELECT is((SELECT e -> 'released_deviations_7d' FROM t41d, jsonb_array_elements(c -> 'candidates') e
            WHERE e ->> 'ref' = (SELECT r ->> 'ref' FROM jsonb_array_elements(c -> 'refs') r
                                  WHERE r ->> 'person_id' = 'b1100000-0000-0000-0000-000000000019')),
  '["session_load.above"]'::jsonb, 'Q9: released_deviations_7d als statement_key-Liste');
SELECT ok((SELECT NOT ((c -> 'candidates')::text ILIKE '%pain%') FROM t41d), 'kein pain_max-Schluessel bei Modul an');

-- -----------------------------------------------------------------------------
-- 6. Keine Kandidaten: keine Protokollzeile
-- -----------------------------------------------------------------------------
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-000000000013', 'j1')), 'j1 fuer Q3 weg');
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-000000000014', 'j1')), 'j1 fuer Q4 weg');
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-000000000019', 'h4')), 'h4 fuer Q9 weg');
SELECT is(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000001', 60::smallint, 6::smallint),
  '{"refs": [], "call_id": null, "candidates": []}'::jsonb, 'alle Kandidaten weggeklickt: leer');
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 4,
  'ohne Kandidaten keine neue Protokollzeile (weiterhin vier)');
-- Die zweite Einheit (morgen, Typ gym) ist davon unberuehrt: Wegklicks gelten je
-- Einheit. Dort sind Q3, Q4, Q9 und auch QB (j1 nur fuer Einheit 1) und QC (h1 nur
-- fuer Einheit 1) Kandidaten.
SELECT is(array_length(app._t41_cand_people(app.rpc_squad_check_jev_context('b1200000-0000-0000-0000-000000000002', 60::smallint, 6::smallint)), 1),
  5, 'Wegklicks gelten je Einheit: die zweite Einheit hat fuenf Kandidaten');

-- -----------------------------------------------------------------------------
-- 7. app.rpc_finish_model_call
-- -----------------------------------------------------------------------------
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000003', 'athletic_coach');
SELECT ok(app.is_denial(app.rpc_finish_model_call((SELECT (c ->> 'call_id')::bigint FROM t41a), 'ok', 120)),
  'fremde Person im selben Team: deny');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000008', 'coach', 'b1000000-0000-0000-0000-000000000008');
SELECT ok(app.is_denial(app.rpc_finish_model_call((SELECT (c ->> 'call_id')::bigint FROM t41a), 'ok', 120)),
  'fremdes Team: deny');
SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok(format($$ SELECT app.rpc_finish_model_call(%s, 'pending', 1) $$, (SELECT c ->> 'call_id' FROM t41a)),
  '22023', NULL, 'result_class pending ist kein Abschluss: 22023');
SELECT throws_ok(format($$ SELECT app.rpc_finish_model_call(%s, 'great', 1) $$, (SELECT c ->> 'call_id' FROM t41a)),
  '22023', NULL, 'unbekannte result_class: 22023');
SELECT is((SELECT result_class FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)), 'pending',
  'nach den Ablehnungen weiterhin pending');
SELECT ok(NOT app.is_denial(app.rpc_finish_model_call((SELECT (c ->> 'call_id')::bigint FROM t41a), 'partial', 120)),
  'eigene pending-Zeile: Abschluss erlaubt');
SELECT is((SELECT row(result_class, latency_ms, finished_at IS NOT NULL)::text FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41a)),
  row('partial', 120, true)::text, 'result_class, latency_ms und finished_at gesetzt');
SELECT ok(app.is_denial(app.rpc_finish_model_call((SELECT (c ->> 'call_id')::bigint FROM t41a), 'ok', 1)),
  'eine abgeschlossene Zeile ist nicht erneut aenderbar');
UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes' WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41b);
SELECT ok(app.is_denial(app.rpc_finish_model_call((SELECT (c ->> 'call_id')::bigint FROM t41b), 'timeout', 3000)),
  'aelter als 5 Minuten: deny');
SELECT is((SELECT result_class FROM app.model_call_log WHERE id = (SELECT (c ->> 'call_id')::bigint FROM t41b)), 'pending',
  'die alte Zeile bleibt sichtbar pending');
SELECT ok(app.is_denial(public.rpc_finish_model_call(-1, 'ok', 1)), 'Tuer: unbekannte id -> Ablehnungsobjekt');
SELECT is(current_setting('response.status', true), '403', 'Tuer setzt HTTP 403');

-- -----------------------------------------------------------------------------
-- 8. T2 (ADR-019): kein Schreiben auf medical_clearances/readiness_scores
-- -----------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_proc p
            WHERE p.pronamespace IN ('app'::regnamespace, 'public'::regnamespace)
              AND p.proname IN ('_module_flag_setters','rpc_set_module_flag','rpc_squad_check_jev_context','rpc_finish_model_call')
              AND p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(app\.)?(medical_clearances|readiness_scores)'),
  0, 'T2: keine AP-69-Funktion aus 41 schreibt medical_clearances oder readiness_scores');
SELECT is((SELECT count(*)::int FROM pg_proc p
            WHERE p.pronamespace IN ('app'::regnamespace, 'public'::regnamespace)
              AND p.proname IN ('_module_flag_setters','rpc_set_module_flag','rpc_squad_check_jev_context','rpc_finish_model_call')),
  7, 'T2 prueft alle sieben Funktionen (vier app, drei Tueren)');
SELECT ok((SELECT prosrc !~* 'rpc_set_clearance|medical_status_badge|value_sport' FROM pg_proc
            WHERE oid = 'app.rpc_squad_check_jev_context(uuid,smallint,smallint)'::regprocedure),
  'T2: die JEV-Tuer ruft weder rpc_set_clearance noch Badge oder value_sport');

-- -----------------------------------------------------------------------------
-- 9. T6: rpc_shred_person erfasst Aufrufprotokoll und Wegklicks
-- -----------------------------------------------------------------------------
-- Ausgangslage: Q3 steht als Betroffene in model_call_subjects und hat einen
-- Wegklick (j1). Der Coach ist Ausloeser aller Protokollzeilen und hat die
-- Wegklicks angelegt.
SELECT ok((SELECT count(*) FROM app.model_call_subjects WHERE person_id = 'b1100000-0000-0000-0000-000000000013') > 0,
  'T6 Vorbedingung: Q3 steht in model_call_subjects');
SELECT ok((SELECT count(*) FROM app.session_hint_dismissals WHERE person_id = 'b1100000-0000-0000-0000-000000000013') > 0,
  'T6 Vorbedingung: Q3 hat einen Wegklick');
SELECT ok((SELECT count(*) FROM app.model_call_log WHERE actor_id = 'b1100000-0000-0000-0000-000000000002') > 0,
  'T6 Vorbedingung: der Coach ist Ausloeser im Protokoll');

SELECT app._t41_jwt('b1100000-0000-0000-0000-000000000005', 'admin');
SELECT lives_ok($$ SELECT app.rpc_shred_person('b1100000-0000-0000-0000-000000000013') $$, 'admin schreddert Q3');
SELECT is((SELECT (SELECT count(*) FROM app.model_call_subjects s WHERE s::text LIKE '%b1100000-0000-0000-0000-000000000013%')
                + (SELECT count(*) FROM app.model_call_log l WHERE l::text LIKE '%b1100000-0000-0000-0000-000000000013%')
                + (SELECT count(*) FROM app.session_hint_dismissals d WHERE d::text LIKE '%b1100000-0000-0000-0000-000000000013%'))::int,
  0, 'T6: die id von Q3 ist danach 0 Mal in model_call_subjects/model_call_log/session_hint_dismissals');
SELECT is((SELECT count(*)::int FROM app.model_call_subjects WHERE person_id = 'b1100000-0000-0000-0000-000000000014'), 5,
  'T6: die Subjects anderer Personen bleiben (Q4 in fuenf Aufrufen)');
SELECT is((SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'b1000000-0000-0000-0000-000000000001'), 5,
  'T6: keine Protokollzeile geloescht');

SELECT lives_ok($$ SELECT app.rpc_shred_person('b1100000-0000-0000-0000-000000000002') $$, 'admin schreddert den Coach (Ausloeser)');
SELECT is((SELECT (SELECT count(*) FROM app.model_call_log l WHERE l::text LIKE '%b1100000-0000-0000-0000-000000000002%')
                + (SELECT count(*) FROM app.session_hint_dismissals d WHERE d::text LIKE '%b1100000-0000-0000-0000-000000000002%'))::int,
  0, 'T6: die id des Coachs ist danach 0 Mal in model_call_log/session_hint_dismissals');
SELECT is((SELECT count(*)::int FROM app.model_call_log
            WHERE team_id = 'b1000000-0000-0000-0000-000000000001' AND actor_kind = 'job' AND job_key = 'shredded'
              AND actor_id IS NULL AND actor_role IS NULL), 5,
  'T6: alle fuenf Zeilen bleiben als Nachweis, Ausloeser anonymisiert (job/shredded)');
SELECT is((SELECT count(*)::int FROM app.session_hint_dismissals
            WHERE team_id = 'b1000000-0000-0000-0000-000000000001' AND dismissed_by IS NULL), 4,
  'T6: Wegklicks des Coachs fuer andere Personen bleiben, dismissed_by NULL');

SELECT * FROM finish();
ROLLBACK;
