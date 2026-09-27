-- =============================================================================
-- 40_squad_check.pgtap.sql — AP-69 Plan gegen Zustand, Regel v1
--
-- Prueft backend/40_squad_check.sql: Struktur und Rechte (session_hint_
-- dismissals ohne jeden Client-Zugriff, interne Funktionen nicht ausfuehrbar),
-- Muster-D-Rollenmatrix der drei RPCs, die Entscheidungstabelle v1 vollstaendig
-- (alle vier Freigabestufen, h1 und h2, h2 allein mit z >= 2 gegen z < 2, h3
-- loest nie einen Vorschlag aus, keine Baseline -> no_norm), h4 nur bei
-- eingeschaltetem LoadDeviation-Modul und nur freigegeben/ohne pain_max/7 Tage,
-- Tagessumme mit Selbstausschluss ueber p_session_id, Wegklicken teamweit und
-- wiederherstellbar, Freigabe-Spiegel nie wegklickbar, T2 (kein Schreiben auf
-- medical_clearances/readiness_scores im prosrc).
-- Laeuft in einer Transaktion und rollt zurueck, die Test-DB bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(93);

-- -----------------------------------------------------------------------------
-- Fixtures (als Superuser)
-- -----------------------------------------------------------------------------
-- Geplante Tageslast des Entwurfs: Intensitaet 6 x 60 min = 360, keine andere
-- Einheit am Tag. z = (360 - median) / greatest(sigma, 60) (sigma_floor 60).
--   P1 full,     Band low,  median 280 -> z 1,33 above     -> h1+h2 -> reduced
--   P2 keine,    Band high, median 200 -> z 2,67 far_above -> h2>=2 -> reduced
--   P3 full,     Band high, median 280 -> z 1,33 above     -> h2<2  -> full
--   P4 full,     Band low,  median 360 -> z 0    normal    -> h1    -> full
--   P5 full,     kein Check-in, keine Baseline -> h3 only, no_norm   -> full
--   P6 blocked,  Band low,  median 200 -> suspend (mirror)
--   P7 individual                      -> individual (mirror)
--   P8 limited                         -> reduced (mirror)
--   P9 full,     Band high, median 360 -> nur h4 (Modul an)          -> full

INSERT INTO app.teams (id, name, timezone) VALUES
  ('a9000000-0000-0000-0000-000000000001','Team A9','Europe/Berlin'),
  ('a9000000-0000-0000-0000-000000000008','Team A9b (fremd)','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('a9100000-0000-0000-0000-000000000002','a9000000-0000-0000-0000-000000000001','Coach A9',NULL,NULL,'a9100000-0000-0000-0000-000000000002',true),
  ('a9100000-0000-0000-0000-000000000003','a9000000-0000-0000-0000-000000000001','Athletik A9',NULL,NULL,'a9100000-0000-0000-0000-000000000003',true),
  ('a9100000-0000-0000-0000-000000000004','a9000000-0000-0000-0000-000000000001','Aerztin A9',NULL,NULL,'a9100000-0000-0000-0000-000000000004',true),
  ('a9100000-0000-0000-0000-000000000005','a9000000-0000-0000-0000-000000000001','Admin A9',NULL,NULL,'a9100000-0000-0000-0000-000000000005',true),
  ('a9100000-0000-0000-0000-000000000011','a9000000-0000-0000-0000-000000000001','P1','sturm',11,'a9100000-0000-0000-0000-000000000011',true),
  ('a9100000-0000-0000-0000-000000000012','a9000000-0000-0000-0000-000000000001','P2','sturm',12,NULL,true),
  ('a9100000-0000-0000-0000-000000000013','a9000000-0000-0000-0000-000000000001','P3','abwehr',13,NULL,true),
  ('a9100000-0000-0000-0000-000000000014','a9000000-0000-0000-0000-000000000001','P4','abwehr',14,NULL,true),
  ('a9100000-0000-0000-0000-000000000015','a9000000-0000-0000-0000-000000000001','P5','tor',15,NULL,true),
  ('a9100000-0000-0000-0000-000000000016','a9000000-0000-0000-0000-000000000001','P6','mitte',16,NULL,true),
  ('a9100000-0000-0000-0000-000000000017','a9000000-0000-0000-0000-000000000001','P7','mitte',17,NULL,true),
  ('a9100000-0000-0000-0000-000000000018','a9000000-0000-0000-0000-000000000001','P8','mitte',18,NULL,true),
  ('a9100000-0000-0000-0000-000000000019','a9000000-0000-0000-0000-000000000001','P9','mitte',19,NULL,true),
  ('a9100000-0000-0000-0000-000000000008','a9000000-0000-0000-0000-000000000008','Coach A9b',NULL,NULL,'a9100000-0000-0000-0000-000000000008',true),
  ('a9100000-0000-0000-0000-000000000009','a9000000-0000-0000-0000-000000000008','Spielerin A9b','sturm',9,NULL,true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id
         WHEN 'a9100000-0000-0000-0000-000000000002' THEN 'coach'
         WHEN 'a9100000-0000-0000-0000-000000000003' THEN 'athletic_coach'
         WHEN 'a9100000-0000-0000-0000-000000000004' THEN 'doctor'
         WHEN 'a9100000-0000-0000-0000-000000000005' THEN 'admin'
         WHEN 'a9100000-0000-0000-0000-000000000008' THEN 'coach'
         ELSE 'player'
       END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'a91%';

CREATE OR REPLACE FUNCTION app._t40_jwt(p_sub text, p_role text, p_team text DEFAULT 'a9000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- Ein Personenobjekt aus dem Ergebnis ziehen.
CREATE OR REPLACE FUNCTION app._t40_row(p_result jsonb, p_person text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT a FROM jsonb_array_elements(p_result -> 'athletes') a WHERE a ->> 'person_id' = p_person;
$$;

INSERT INTO app.medical_clearances (team_id, person_id, status, valid_from, set_by_role) VALUES
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000011','full',       now() - interval '10 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000013','full',       now() - interval '10 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000014','full',       now() - interval '10 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000015','full',       now() - interval '10 days','doctor'),
  -- P6: aeltere full-Zeile plus juengere blocked-Zeile, die juengere gilt.
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000016','full',       now() - interval '20 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000016','blocked',    now() - interval '2 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000017','individual', now() - interval '2 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000018','limited',    now() - interval '2 days','doctor'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','full',       now() - interval '10 days','doctor');

-- Check-in heute fuer alle ausser P5.
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at, checkin_submitted_at)
SELECT 'a9000000-0000-0000-0000-000000000001', p.id, current_date, 5, now(), now()
  FROM app.persons p
 WHERE p.id IN ('a9100000-0000-0000-0000-000000000011','a9100000-0000-0000-0000-000000000012',
                'a9100000-0000-0000-0000-000000000013','a9100000-0000-0000-0000-000000000014',
                'a9100000-0000-0000-0000-000000000016','a9100000-0000-0000-0000-000000000017',
                'a9100000-0000-0000-0000-000000000018','a9100000-0000-0000-0000-000000000019');
-- P5: nur eine reine Trainingslast-Zeile (kein echter Check-in).
INSERT INTO app.daily_checkins (team_id, person_id, date, session_load)
VALUES ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000015', current_date, 100);

INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors) VALUES
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000011', current_date, 3.0,'low','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000012', current_date, 8.0,'high','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000013', current_date, 8.0,'high','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000014', current_date, 3.0,'low','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000016', current_date, 3.0,'low','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000017', current_date, 8.0,'high','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000018', current_date, 8.0,'high','{}'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019', current_date, 8.0,'high','{}');

INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status) VALUES
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000011','session_load', current_date, 20, 280, 60,'neutral','ok'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000012','session_load', current_date, 20, 200, 30,'neutral','ok'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000013','session_load', current_date, 20, 280, 60,'neutral','ok'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000014','session_load', current_date, 20, 360, 60,'neutral','ok'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000016','session_load', current_date, 20, 200, 60,'neutral','ok'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','session_load', current_date, 20, 360, 60,'neutral','ok'),
  -- P5: nur eine nicht belastbare Baseline -> no_norm.
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000015','session_load', current_date, 5, 100, 60,'neutral','insufficient');

-- P9: eine freigegebene Lastabweichung (zaehlt), eine freigegebene pain_max
-- (zaehlt nie), eine unveroeffentlichte (zaehlt nie), eine zu alte (zaehlt nie).
INSERT INTO app.load_deviations (team_id, person_id, metric, date, deviation, state, statement_key) VALUES
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','session_load',  current_date - 2, 40,'released',  'session_load.above'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','pain_max',      current_date - 1, 50,'released',  'pain_max.above'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','sleep_quality', current_date - 1,-30,'unreviewed','sleep_quality.below'),
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000019','recovery',      current_date - 8,-30,'released',  'recovery.below'),
  -- P3: nur eine unveroeffentlichte -> nie h4.
  ('a9000000-0000-0000-0000-000000000001','a9100000-0000-0000-0000-000000000013','recovery',      current_date - 1,-30,'unreviewed','recovery.below');

-- -----------------------------------------------------------------------------
-- 1. Struktur und Rechte
-- -----------------------------------------------------------------------------
SELECT has_table('app', 'session_hint_dismissals', 'app.session_hint_dismissals existiert');
SELECT ok((SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'app.session_hint_dismissals'::regclass),
  'session_hint_dismissals: RLS an und erzwungen');
SELECT ok(NOT has_table_privilege('authenticated', 'app.session_hint_dismissals', 'SELECT'),
  'authenticated hat kein SELECT auf session_hint_dismissals');
SELECT ok(NOT has_table_privilege('authenticated', 'app.session_hint_dismissals', 'INSERT'),
  'authenticated hat kein INSERT auf session_hint_dismissals');
SELECT ok(NOT has_table_privilege('anon', 'app.session_hint_dismissals', 'SELECT'),
  'anon hat kein SELECT auf session_hint_dismissals');
SELECT ok(NOT has_function_privilege('authenticated', 'app._squad_check_v1(uuid,date,smallint,smallint,uuid)', 'EXECUTE'),
  'authenticated darf app._squad_check_v1 nicht direkt ausfuehren');
SELECT ok(NOT has_function_privilege('authenticated', 'app._squad_check_clearance(uuid,uuid)', 'EXECUTE'),
  'authenticated darf app._squad_check_clearance nicht direkt ausfuehren');
SELECT ok(has_function_privilege('authenticated', 'public.rpc_get_session_squad_check(date,smallint,smallint,uuid)', 'EXECUTE'),
  'Tuer rpc_get_session_squad_check fuer authenticated');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_get_session_squad_check(date,smallint,smallint,uuid)', 'EXECUTE'),
  'Tuer rpc_get_session_squad_check nicht fuer anon');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_dismiss_session_hint(uuid,uuid,text)', 'EXECUTE'),
  'Tuer rpc_dismiss_session_hint nicht fuer anon');
SELECT ok(NOT has_function_privilege('anon', 'app.rpc_restore_session_hint(uuid,uuid,text)', 'EXECUTE'),
  'app.rpc_restore_session_hint nicht fuer anon');
SELECT throws_ok(
  $$INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version)
    VALUES ('a9000000-0000-0000-0000-000000000001', gen_random_uuid(), 'a9100000-0000-0000-0000-000000000011', 'h3', 'v1')$$,
  '23514', NULL, 'CHECK: h3 ist kein wegklickbarer Schluessel');

-- -----------------------------------------------------------------------------
-- 2. Rollenmatrix rpc_get_session_squad_check
-- -----------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', '', true);
SELECT ok(app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'ohne bestaetigte Claims: deny');

SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000011', 'player');
SELECT ok(app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'player: deny');
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'doctor: deny (nur Staff)');
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000005', 'admin');
SELECT ok(app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'admin: deny (nur Staff)');
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000002', 'coach', 'a9000000-0000-0000-0000-000000000008');
SELECT ok(app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'coach mit falschem team_id-Claim: deny');

SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000003', 'athletic_coach');
SELECT ok(NOT app.is_denial(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'athletic_coach: erlaubt');

SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok($$ SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 11::smallint, NULL) $$,
  '22023', NULL, 'Intensitaet 11: 22023');
SELECT throws_ok($$ SELECT app.rpc_get_session_squad_check(current_date, 0::smallint, 6::smallint, NULL) $$,
  '22023', NULL, 'Dauer 0: 22023');

-- -----------------------------------------------------------------------------
-- 3. Entscheidungstabelle v1 (Entwurf, LoadDeviation-Modul aus)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE t40 AS
  SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL) AS r;

SELECT is((SELECT r ->> 'rule_version' FROM t40), 'v1', 'Regelversion v1');
SELECT is((SELECT (r ->> 'planned_day_load')::numeric FROM t40), 360::numeric, 'geplante Tageslast Entwurf 6 x 60 = 360');
SELECT is((SELECT jsonb_array_length(r -> 'athletes') FROM t40), 9, 'nur die neun aktiven Spielerinnen des eigenen Teams, kein Staff, kein fremdes Team');
SELECT ok((SELECT NOT (r::text LIKE '%a9100000-0000-0000-0000-000000000009%') FROM t40), 'fremde Spielerin taucht nicht auf');

-- P1: h1 + h2 -> reduced (rule)
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') ->> 'suggestion' FROM t40), 'reduced', 'P1 h1 und h2: reduziert');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') ->> 'source' FROM t40), 'rule', 'P1 Quelle rule');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') -> 'hints' FROM t40), '["h1","h2"]'::jsonb, 'P1 Hinweise h1,h2');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') ->> 'load_level' FROM t40), 'above', 'P1 Laststufe above (1 <= z < 2)');
-- P2: h2 mit z >= 2 allein -> reduced
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000012') ->> 'suggestion' FROM t40), 'reduced', 'P2 h2 mit z >= 2 allein: reduziert');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000012') ->> 'load_level' FROM t40), 'far_above', 'P2 Laststufe far_above');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000012') ->> 'clearance' FROM t40), NULL, 'P2 keine Freigabezeile -> clearance NULL, wie full behandelt');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000012') -> 'hints' FROM t40), '["h2"]'::jsonb, 'P2 Hinweis nur h2');
-- sigma unter sigma_floor: P2 sigma 30, gerechnet wird mit 60 (z 2,67 statt 5,33) -- beides far_above,
-- der Floor selbst ist ueber P3/P1 (sigma = floor) abgedeckt.
-- P3: h2 mit z < 2 allein -> full
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000013') ->> 'suggestion' FROM t40), 'full', 'P3 h2 mit z < 2 allein: kein Vorschlag, volle Gruppe');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000013') -> 'hints' FROM t40), '["h2"]'::jsonb, 'P3 Hinweis h2 bleibt sichtbar');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000013') -> 'released_deviation_keys' FROM t40), '[]'::jsonb, 'P3 unveroeffentlichte Abweichung zaehlt nie');
-- P4: h1 allein -> full
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000014') ->> 'suggestion' FROM t40), 'full', 'P4 h1 allein: volle Gruppe');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000014') -> 'hints' FROM t40), '["h1"]'::jsonb, 'P4 Hinweis h1');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000014') ->> 'load_level' FROM t40), 'normal', 'P4 Laststufe normal');
-- P5: h3 loest nie einen Vorschlag aus, keine belastbare Baseline -> no_norm
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000015') ->> 'suggestion' FROM t40), 'full', 'P5 h3 allein: nie ein Vorschlag');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000015') -> 'hints' FROM t40), '["h3"]'::jsonb, 'P5 Hinweis h3 (reine Trainingslast-Zeile ist kein Check-in)');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000015') ->> 'load_level' FROM t40), 'no_norm', 'P5 insufficient-Baseline -> no_norm');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000015') ->> 'has_checkin' FROM t40), 'false', 'P5 has_checkin false');
-- P6-P8: Spiegel
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000016') ->> 'suggestion' FROM t40), 'suspend', 'P6 blocked: aussetzen');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000016') ->> 'source' FROM t40), 'mirror', 'P6 Quelle mirror');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000016') ->> 'clearance' FROM t40), 'blocked', 'P6 die juengere blocked-Zeile gilt, nicht die aeltere full-Zeile');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000017') ->> 'suggestion' FROM t40), 'individual', 'P7 individual: individuell');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000017') ->> 'source' FROM t40), 'mirror', 'P7 Quelle mirror');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000018') ->> 'suggestion' FROM t40), 'reduced', 'P8 limited: reduziert');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000018') ->> 'source' FROM t40), 'mirror', 'P8 Quelle mirror');
-- Statistik eskaliert nie ueber reduziert
SELECT is((SELECT count(*)::int FROM t40, jsonb_array_elements(r -> 'athletes') a
            WHERE a ->> 'source' = 'rule' AND a ->> 'suggestion' IN ('individual','suspend')), 0,
  'Regel v1 leitet nie individuell/aussetzen aus der Statistik ab');
-- P9: Modul aus -> h4 nie aktiv
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000019') -> 'hints' FROM t40), '[]'::jsonb, 'P9 LoadDeviation-Modul aus: kein h4');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000019') -> 'released_deviation_keys' FROM t40), '[]'::jsonb, 'P9 LoadDeviation-Modul aus: Schluesselliste leer');
-- Keine Score-Zahl, keine Faktoren, keine z-Zahl im Ergebnis
SELECT ok((SELECT NOT (r::text ~ '"(score_total|factors|z|pain_max|body_map)"') FROM t40),
  'Ergebnis enthaelt weder score_total, factors, z, pain_max noch body_map als Schluessel');
SELECT ok((SELECT NOT (r::text LIKE '%pain_max.above%') FROM t40), 'kein pain_max-Schluessel im Ergebnis');

DROP TABLE t40;

-- -----------------------------------------------------------------------------
-- 4. h4 bei eingeschaltetem Modul
-- -----------------------------------------------------------------------------
INSERT INTO app.module_flags (team_id, flag, enabled) VALUES ('a9000000-0000-0000-0000-000000000001', 'loaddeviation_enabled', true);

CREATE TEMP TABLE t40 AS
  SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL) AS r;
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000019') -> 'hints' FROM t40), '["h4"]'::jsonb, 'P9 Modul an: h4 aktiv');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000019') -> 'released_deviation_keys' FROM t40), '["session_load.above"]'::jsonb,
  'P9 nur die freigegebene Nicht-pain_max-Abweichung der letzten 7 Tage');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000019') ->> 'suggestion' FROM t40), 'full', 'P9 h4 allein loest keinen Vorschlag aus');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000013') -> 'released_deviation_keys' FROM t40), '[]'::jsonb, 'P3 auch mit Modul an: unveroeffentlicht zaehlt nie');
DROP TABLE t40;

-- -----------------------------------------------------------------------------
-- 5. Gespeicherte Einheit: Selbstausschluss, Tagessumme
-- -----------------------------------------------------------------------------
INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, planned_intensity, created_by) VALUES
  ('a9200000-0000-0000-0000-000000000001','a9000000-0000-0000-0000-000000000001', current_date, 60, 6, 'a9100000-0000-0000-0000-000000000002'),
  ('a9200000-0000-0000-0000-000000000008','a9000000-0000-0000-0000-000000000008', current_date, 60, 6, 'a9100000-0000-0000-0000-000000000008');

SELECT is((app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000001') ->> 'planned_day_load')::numeric,
  360::numeric, 'p_session_id schliesst die gespeicherte Fassung derselben Einheit aus (nicht 720)');
SELECT is((app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL) ->> 'planned_day_load')::numeric,
  720::numeric, 'Entwurf ohne p_session_id: gespeicherte Einheit desselben Tages zaehlt mit');

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, planned_intensity, created_by) VALUES
  ('a9200000-0000-0000-0000-000000000002','a9000000-0000-0000-0000-000000000001', current_date, 30, 2, 'a9100000-0000-0000-0000-000000000002'),
  ('a9200000-0000-0000-0000-000000000003','a9000000-0000-0000-0000-000000000001', current_date, 45, NULL, 'a9100000-0000-0000-0000-000000000002');

CREATE TEMP TABLE t40 AS
  SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000001') AS r;
SELECT is((SELECT (r ->> 'planned_day_load')::numeric FROM t40), 420::numeric,
  'Tagessumme 360 + 2 x 30, Einheit ohne Intensitaet traegt nichts bei, fremdes Team zaehlt nicht');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000014') ->> 'suggestion' FROM t40), 'reduced',
  'P4 kippt mit der zweiten Einheit auf z = 1: h1 und h2 -> reduziert');
DROP TABLE t40;

SELECT throws_ok($$ SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000008') $$,
  'P0002', NULL, 'fremde Einheit: P0002');
SELECT throws_ok($$ SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, gen_random_uuid()) $$,
  'P0002', NULL, 'unbekannte Einheit: P0002');

DELETE FROM app.training_sessions WHERE id IN ('a9200000-0000-0000-0000-000000000002','a9200000-0000-0000-0000-000000000003');

-- -----------------------------------------------------------------------------
-- 6. Wegklicken
-- -----------------------------------------------------------------------------
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h2')),
  'coach klickt h2 fuer P1 weg');
SELECT is((SELECT dismissed_by FROM app.session_hint_dismissals
            WHERE session_id = 'a9200000-0000-0000-0000-000000000001' AND person_id = 'a9100000-0000-0000-0000-000000000011'),
  'a9100000-0000-0000-0000-000000000002'::uuid, 'dismissed_by kommt aus dem Auth-Helfer');
SELECT is((SELECT rule_version FROM app.session_hint_dismissals
            WHERE session_id = 'a9200000-0000-0000-0000-000000000001' AND person_id = 'a9100000-0000-0000-0000-000000000011'),
  'v1', 'rule_version v1 gespeichert');
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h2')),
  'zweiter Wegklick ist idempotent');
SELECT is((SELECT count(*)::int FROM app.session_hint_dismissals WHERE session_id = 'a9200000-0000-0000-0000-000000000001'), 1,
  'genau eine Zeile nach doppeltem Wegklick');

-- Teamweit: die Athletiktrainerin sieht denselben Stand.
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000003', 'athletic_coach');
CREATE TEMP TABLE t40 AS
  SELECT app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000001') AS r;
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') ->> 'suggestion' FROM t40), 'full',
  'P1 nach Wegklick von h2: volle Gruppe (auch fuer die zweite Trainerin)');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') -> 'hints' FROM t40), '["h1"]'::jsonb, 'P1 aktiver Hinweis nur noch h1');
SELECT is((SELECT app._t40_row(r, 'a9100000-0000-0000-0000-000000000011') -> 'dismissed_hints' FROM t40), '["h2"]'::jsonb, 'P1 weggeklickt h2');
DROP TABLE t40;
SELECT is((app._t40_row(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL), 'a9100000-0000-0000-0000-000000000011') ->> 'suggestion'),
  'reduced', 'Entwurf ohne p_session_id kennt keine Wegklicks');

SELECT ok((app.rpc_restore_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h2') ->> 'restored')::boolean,
  'athletic_coach stellt h2 wieder her');
SELECT is((app._t40_row(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000001'), 'a9100000-0000-0000-0000-000000000011') ->> 'suggestion'),
  'reduced', 'nach Wiederherstellen wieder reduziert');

SELECT throws_ok($$ SELECT app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h3') $$,
  '22023', NULL, 'h3 ist nicht wegklickbar: 22023');
SELECT throws_ok($$ SELECT app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'mirror') $$,
  '22023', NULL, 'unbekannter Schluessel: 22023');
SELECT throws_ok($$ SELECT app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000008', 'a9100000-0000-0000-0000-000000000011', 'h1') $$,
  'P0002', NULL, 'fremde Einheit beim Wegklicken: P0002');
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000009', 'h1')),
  'Spielerin aus fremdem Team: deny');

-- Spiegel sind nie wegklickbar, auch nicht ueber einen Hinweis-Schluessel.
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000016', 'h1')),
  'Spiegel aussetzen (blocked): Wegklick abgelehnt');
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000017', 'j1')),
  'Spiegel individuell: Wegklick abgelehnt');
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000018', 'h2')),
  'Spiegel reduziert (limited): Wegklick abgelehnt');
SELECT is((SELECT count(*)::int FROM app.session_hint_dismissals
            WHERE person_id IN ('a9100000-0000-0000-0000-000000000016','a9100000-0000-0000-0000-000000000017','a9100000-0000-0000-0000-000000000018')),
  0, 'fuer keinen Spiegel existiert ein Wegklick-Datensatz');
SELECT is((app._t40_row(app.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, 'a9200000-0000-0000-0000-000000000001'), 'a9100000-0000-0000-0000-000000000016') ->> 'suggestion'),
  'suspend', 'P6 bleibt aussetzen');

SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000011', 'player');
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h1')),
  'player darf nicht wegklicken');
SELECT ok(app.is_denial(app.rpc_restore_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h1')),
  'player darf nicht wiederherstellen');
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000005', 'admin');
SELECT ok(app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000011', 'h1')),
  'admin darf nicht wegklicken (nur Staff)');

-- Loeschen der Einheit nimmt ihre Wegklicks mit (FK CASCADE).
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(NOT app.is_denial(app.rpc_dismiss_session_hint('a9200000-0000-0000-0000-000000000001', 'a9100000-0000-0000-0000-000000000014', 'h1')),
  'coach klickt h1 fuer P4 weg');
DELETE FROM app.training_sessions WHERE id = 'a9200000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*)::int FROM app.session_hint_dismissals WHERE session_id = 'a9200000-0000-0000-0000-000000000001'), 0,
  'Loeschen der Einheit loescht ihre Wegklicks (CASCADE)');

-- -----------------------------------------------------------------------------
-- 7. Tueren in public: Ablehnung mit HTTP 403
-- -----------------------------------------------------------------------------
SELECT app._t40_jwt('a9100000-0000-0000-0000-000000000011', 'player');
SELECT ok(app.is_denial(public.rpc_get_session_squad_check(current_date, 60::smallint, 6::smallint, NULL)),
  'Tuer liefert das Ablehnungsobjekt fuer player');
SELECT is(current_setting('response.status', true), '403', 'Tuer setzt HTTP 403');

-- -----------------------------------------------------------------------------
-- 8. T2 (ADR-019): kein Schreiben auf medical_clearances/readiness_scores
-- -----------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM pg_proc p
            WHERE p.pronamespace IN ('app'::regnamespace, 'public'::regnamespace)
              AND p.proname IN ('_squad_check_v1','_squad_check_clearance','rpc_get_session_squad_check',
                                'rpc_dismiss_session_hint','rpc_restore_session_hint')
              AND p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(app\.)?(medical_clearances|readiness_scores)'),
  0, 'T2: keine AP-69-Funktion aus 40 schreibt medical_clearances oder readiness_scores');
SELECT is((SELECT count(*)::int FROM pg_proc p
            WHERE p.pronamespace IN ('app'::regnamespace, 'public'::regnamespace)
              AND p.proname IN ('_squad_check_v1','_squad_check_clearance','rpc_get_session_squad_check',
                                'rpc_dismiss_session_hint','rpc_restore_session_hint')),
  8, 'T2 prueft alle acht Funktionen (fuenf app, drei Tueren)');

SELECT * FROM finish();
ROLLBACK;
