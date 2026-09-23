-- =============================================================================
-- 31_medical_doors.pgtap.sql — AP-47a
--
-- Prueft 30_clearance_proposals.sql und 31_medical_doors.sql.
--
-- WAS HIER NICHT GEPRUEFT WERDEN KANN: dass nach einer Ablehnung nichts in
-- app.access_log, app.medical_clearances oder app.clearance_proposals stehen
-- BLEIBT, und dass die Ablehnungszeile in app.access_denials die Transaktion
-- ueberlebt. Die Suite laeuft in einer Transaktion und rollt am Ende zurueck,
-- ein "nichts gewachsen" waere hier wertlos (Lessons Learned, Befund F1).
-- Diese Haelfte ist im Autocommit gemessen, je Aussage ein eigener psql -f
-- Lauf, mit zwei Teams und gegen beide Staende: Audit 2026-09-21, Abschnitt 15.
--
-- Die Suite prueft die andere Haelfte: welche Rolle durch welche Tuer kommt,
-- welche Schluessel die Antwort je Rolle traegt, dass jeder lesende Zugriff
-- genau eine Protokollzeile schreibt, und dass ein Vorschlag keine Freigabe ist.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(72);

-- -----------------------------------------------------------------------------
-- Fixtures: zwei Teams. Staff, Medizin und Admin nur in a1.
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
  ('b1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Spielerin A1','stuermerin','b1000000-0000-0000-0000-000000000001',true),
  ('b1000000-0000-0000-0000-000000000009','a1000000-0000-0000-0000-000000000001','Zweite A1','abwehr','b1000000-0000-0000-0000-000000000009',true),
  ('b2000000-0000-0000-0000-000000000002','a2000000-0000-0000-0000-000000000002','Spielerin A2','stuermerin','b2000000-0000-0000-0000-000000000002',true);
INSERT INTO app.role_assignments (team_id, person_id, role) VALUES
  ('a1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','coach'),
  ('a1000000-0000-0000-0000-000000000001','c2000000-0000-0000-0000-000000000002','athletic_coach'),
  ('a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','physio'),
  ('a1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','doctor'),
  ('a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','admin'),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','player'),
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000009','player'),
  ('a2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000002','player');
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, energy, training_readiness, body_map, pain_max) VALUES
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001', current_date - 1, 4, 3, 4, '{"knie_l":6}'::jsonb, 6),
  ('a2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000002', current_date - 1, 3, 2, 2, '{"ruecken":8}'::jsonb, 8);
INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors) VALUES
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001', current_date - 1, 81.0, 'moderate', '{"sleep":0.8,"soreness":0.4}'::jsonb);
INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('f1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001', current_date - 1, 22.5, 'unreviewed');
INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','limited','Nur Rad', current_date - 1,'d2000000-0000-0000-0000-000000000002','doctor');

CREATE OR REPLACE FUNCTION app._t31_jwt(p_sub text, p_role text, p_team text DEFAULT 'a1000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;
CREATE OR REPLACE FUNCTION app._t31_denied(p jsonb, p_msg text) RETURNS boolean LANGUAGE sql AS $$
  SELECT app.is_denial(p) AND p->>'message' = p_msg;
$$;

-- -----------------------------------------------------------------------------
-- 1. Die Rollenmatrix: sechs Rollen mal sechs Tueren (36)
--    Erlaubt oder FORBIDDEN, so wie Modul 7 Abschnitt 5 es sagt.
--    p_person_id ist ueberall die Spielerin A1, die Tuer wird als public gerufen.
-- -----------------------------------------------------------------------------

-- player: eigene Check-ins und Readiness ja, Freigabe lesen ja, alles Schreibende nein
SELECT app._t31_jwt('b1000000-0000-0000-0000-000000000001','player');
SELECT ok(NOT app.is_denial(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001')),  'player: checkins self erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001')), 'player: readiness self erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')),     'player: Freigabe self erlaubt');
SELECT ok(app._t31_denied(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','release'), 'FORBIDDEN: load_deviations.release'), 'player: deviation FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x'), 'FORBIDDEN: medical_clearances.propose (only physio)'), 'player: propose FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x'), 'FORBIDDEN: medical_clearances.set (only doctor)'), 'player: set FORBIDDEN');

-- coach: Medizin-Gate zu, Freigabe lesen ja
SELECT app._t31_jwt('c1000000-0000-0000-0000-000000000001','coach');
SELECT ok(app._t31_denied(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001'),  'FORBIDDEN: daily_checkins.body_map'),       'coach: checkins FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001'), 'FORBIDDEN: readiness_scores.score_total'),  'coach: readiness FORBIDDEN');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')), 'coach: Freigabe lesen erlaubt');
SELECT ok(app._t31_denied(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','release'), 'FORBIDDEN: load_deviations.release'), 'coach: deviation FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x'), 'FORBIDDEN: medical_clearances.propose (only physio)'), 'coach: propose FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x'), 'FORBIDDEN: medical_clearances.set (only doctor)'), 'coach: set FORBIDDEN');

-- athletic_coach: identisch zu coach. Der Legacy Pfad kannte diese Rolle nicht (N6).
SELECT app._t31_jwt('c2000000-0000-0000-0000-000000000002','athletic_coach');
SELECT ok(app._t31_denied(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001'),  'FORBIDDEN: daily_checkins.body_map'),      'athletic_coach: checkins FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001'), 'FORBIDDEN: readiness_scores.score_total'), 'athletic_coach: readiness FORBIDDEN');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')), 'athletic_coach: Freigabe lesen erlaubt');
SELECT ok(app._t31_denied(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','release'), 'FORBIDDEN: load_deviations.release'), 'athletic_coach: deviation FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x'), 'FORBIDDEN: medical_clearances.propose (only physio)'), 'athletic_coach: propose FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x'), 'FORBIDDEN: medical_clearances.set (only doctor)'), 'athletic_coach: set FORBIDDEN');

-- physio: alles ausser setzen
SELECT app._t31_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok(NOT app.is_denial(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001')),  'physio: checkins erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001')), 'physio: readiness erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')),     'physio: Freigabe lesen erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','release')), 'physio: deviation erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x')), 'physio: propose erlaubt');
SELECT ok(app._t31_denied(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x'), 'FORBIDDEN: medical_clearances.set (only doctor)'), 'physio: set FORBIDDEN (ADR-017 D3)');

-- doctor: alles ausser vorschlagen
SELECT app._t31_jwt('d2000000-0000-0000-0000-000000000002','doctor');
SELECT ok(NOT app.is_denial(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001')),  'doctor: checkins erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001')), 'doctor: readiness erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')),     'doctor: Freigabe lesen erlaubt');
SELECT ok(NOT app.is_denial(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','dismiss')), 'doctor: deviation erlaubt');
SELECT ok(app._t31_denied(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x'), 'FORBIDDEN: medical_clearances.propose (only physio)'), 'doctor: propose FORBIDDEN (die Aerztin setzt, sie schlaegt nicht vor)');
SELECT ok(NOT app.is_denial(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x')), 'doctor: set erlaubt');

-- admin: nur die Freigabe lesen (ADR-018), sonst nichts
SELECT app._t31_jwt('e1000000-0000-0000-0000-000000000001','admin');
SELECT ok(app._t31_denied(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001'),  'FORBIDDEN: daily_checkins.body_map'),      'admin: checkins FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_medical_readiness('b1000000-0000-0000-0000-000000000001'), 'FORBIDDEN: readiness_scores.score_total'), 'admin: readiness FORBIDDEN');
SELECT ok(NOT app.is_denial(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')), 'admin: Freigabe lesen erlaubt (ADR-018)');
SELECT ok(app._t31_denied(public.rpc_review_deviation('f1000000-0000-0000-0000-000000000001','release'), 'FORBIDDEN: load_deviations.release'), 'admin: deviation FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','limited','x'), 'FORBIDDEN: medical_clearances.propose (only physio)'), 'admin: propose FORBIDDEN');
SELECT ok(app._t31_denied(public.rpc_set_clearance('b1000000-0000-0000-0000-000000000001','full','x'), 'FORBIDDEN: medical_clearances.set (only doctor)'), 'admin: set FORBIDDEN (ADR-018 aendert nur die Lesezeile)');

-- -----------------------------------------------------------------------------
-- 2. Verbotene Schluessel je Rolle (8)
--    ADR-017 Abschnitt 4.2: was die Rolle nicht sehen darf, verlaesst die
--    Datenbank nicht. Geprueft wird der Payload, nicht die Oberflaeche.
-- -----------------------------------------------------------------------------
SELECT app._t31_jwt('c1000000-0000-0000-0000-000000000001','coach');
SELECT ok((public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'clearance') ?& array['status','load_note'],
  'coach bekommt status und load_note');
SELECT ok(NOT ((public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'clearance') ?| array['set_by','set_by_role','proposed_by']),
  'coach bekommt weder set_by noch set_by_role noch proposed_by');
SELECT is(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'open_proposals', 'null'::jsonb,
  'coach bekommt keinen Vorschlag zu sehen -- ADR-017 3: nie ein Grund');

SELECT app._t31_jwt('e1000000-0000-0000-0000-000000000001','admin');
SELECT ok(NOT ((public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'clearance') ?| array['set_by','set_by_role','proposed_by']),
  'admin bekommt keine Angabe ueber die handelnde Medizinperson');
SELECT is(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'open_proposals', 'null'::jsonb,
  'admin bekommt keinen Vorschlag zu sehen (ADR-018 nennt status und load_note, sonst nichts)');

SELECT app._t31_jwt('b1000000-0000-0000-0000-000000000001','player');
SELECT is(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'open_proposals', 'null'::jsonb,
  'die Spielerin selbst bekommt den Vorschlag ebenfalls nicht');

SELECT app._t31_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok((public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'clearance') ?& array['set_by','set_by_role'],
  'physio bekommt set_by und set_by_role');
SELECT ok(jsonb_typeof(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'open_proposals') = 'array',
  'physio bekommt die offenen Vorschlaege als Liste');

-- -----------------------------------------------------------------------------
-- 3. Ein Vorschlag ist keine Freigabe (Befund A4) (4)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _a4 AS SELECT (SELECT count(*) FROM app.medical_clearances)  AS clr,
                                (SELECT count(*) FROM app.clearance_proposals) AS prop;
SELECT app._t31_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok(NOT app.is_denial(public.rpc_propose_clearance('b1000000-0000-0000-0000-000000000001','blocked','Verdacht')),
  'A4: der Vorschlag laeuft durch');
SELECT is((SELECT count(*) FROM app.clearance_proposals) - (SELECT prop FROM _a4), 1::bigint,
  'A4: genau eine Zeile in clearance_proposals');
SELECT is((SELECT count(*) FROM app.medical_clearances) - (SELECT clr FROM _a4), 0::bigint,
  'A4: und KEINE in medical_clearances');
SELECT app._t31_jwt('d2000000-0000-0000-0000-000000000002','doctor');
SELECT isnt(public.rpc_get_clearance('b1000000-0000-0000-0000-000000000001')->'clearance'->>'status', 'blocked',
  'A4: der Vorschlag der Physio ueberschreibt die Entscheidung der Aerztin NICHT');

-- -----------------------------------------------------------------------------
-- 4. Eine Zeile je Person in der Kaderliste (Befund A4, zweite Haelfte) (1)
-- -----------------------------------------------------------------------------
INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','individual','zweite gueltige Zeile', current_date,'d2000000-0000-0000-0000-000000000002','doctor');
SELECT app._t31_jwt('c1000000-0000-0000-0000-000000000001','coach');
SELECT is((SELECT count(*) FROM jsonb_array_elements(app.rpc_list_team_members()->'members') m WHERE m->>'id' = 'b1000000-0000-0000-0000-000000000001'), 1::bigint,
  'A4: zwei gleichzeitig gueltige Freigaben ergeben trotzdem genau EINE Kaderzeile');

-- -----------------------------------------------------------------------------
-- 5. Protokoll: eine Zeile je lesendem Zugriff, subject = die gelesene Person (5)
--    Befund F2: vorher stand dort die handelnde Person.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _f2 AS SELECT count(*) AS n FROM app.access_log;
SELECT app._t31_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok(NOT app.is_denial(public.rpc_medical_checkins('b1000000-0000-0000-0000-000000000001')), 'F2: die Physio liest eine Spielerin');
SELECT is((SELECT count(*) FROM app.access_log) - (SELECT n FROM _f2), 1::bigint,
  'F2: genau eine Protokollzeile');
SELECT is((SELECT subject_id FROM app.access_log ORDER BY id DESC LIMIT 1), 'b1000000-0000-0000-0000-000000000001'::uuid,
  'F2: subject_id ist die GELESENE Person, nicht die Physio');
SELECT is((SELECT actor_id FROM app.access_log ORDER BY id DESC LIMIT 1), 'd1000000-0000-0000-0000-000000000001'::uuid,
  'F2: actor_id ist die Physio');
SELECT is((SELECT resource FROM app.access_log ORDER BY id DESC LIMIT 1), 'daily_checkins.body_map',
  'F2: die resource nennt das gelesene Feld');

-- -----------------------------------------------------------------------------
-- 6. Befund A3: die Freigabe einer Abweichung wird protokolliert (3)
-- -----------------------------------------------------------------------------
INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('f3000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001', current_date, 18.0, 'unreviewed');
CREATE TEMP TABLE _a3 AS SELECT count(*) AS n FROM app.access_log;
SELECT app._t31_jwt('d1000000-0000-0000-0000-000000000001','physio');
SELECT ok(NOT app.is_denial(public.rpc_review_deviation('f3000000-0000-0000-0000-000000000003','release')), 'A3: die Physio gibt eine Abweichung frei');
SELECT is((SELECT count(*) FROM app.access_log) - (SELECT n FROM _a3), 1::bigint,
  'A3: das schreibt jetzt genau eine Protokollzeile -- vorher gar keine');
SELECT is((SELECT resource||'/'||action FROM app.access_log ORDER BY id DESC LIMIT 1), 'load_deviations/write',
  'A3: die Zeile traegt resource load_deviations und action write');

-- -----------------------------------------------------------------------------
-- 7. Die Tueren selbst (7)
-- -----------------------------------------------------------------------------
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_medical_checkins(uuid, date, date)', 'EXECUTE'),
  'Tuer: anon darf rpc_medical_checkins nicht');
SELECT ok(NOT has_function_privilege('anon', 'public.rpc_set_clearance(uuid, app.app_clearance, text, date, date)', 'EXECUTE'),
  'Tuer: anon darf rpc_set_clearance nicht');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('rpc_medical_checkins','rpc_medical_readiness','rpc_get_clearance',
                               'rpc_review_deviation','rpc_propose_clearance','rpc_set_clearance')
             AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')), 0,
  'Tuer: alle sechs sind fuer authenticated ausfuehrbar');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('rpc_medical_checkins','rpc_medical_readiness','rpc_get_clearance',
                               'rpc_review_deviation','rpc_propose_clearance','rpc_set_clearance')
             AND p.prosecdef), 0,
  'Muster D: keine der sechs Tueren ist SECURITY DEFINER (Befund N9)');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('rpc_medical_checkins','rpc_medical_readiness','rpc_get_clearance',
                               'rpc_review_deviation','rpc_propose_clearance','rpc_set_clearance')
             AND p.provolatile <> 'v'), 0,
  'Muster D Regel 1: keine der sechs Tueren ist STABLE oder IMMUTABLE');
SELECT is((SELECT count(*)::int FROM pg_proc p, aclexplode(p.proacl) a
           WHERE p.pronamespace = 'app'::regnamespace
             AND p.proname IN ('rpc_check_ins_medical','rpc_readiness_full','rpc_release_deviation',
                               'rpc_get_clearance','rpc_set_clearance','rpc_propose_clearance')
             AND a.grantee = 0), 0,
  'Punkt 55: PUBLIC hat auf keiner der sechs app Funktionen ein Recht');
SELECT ok(NOT has_function_privilege('authenticated', 'app.rpc_shred_person(uuid)', 'EXECUTE'),
  'rpc_shred_person hat keine Tuer und behaelt deshalb seinen Entzug aus Punkt 55');

-- -----------------------------------------------------------------------------
-- 8. Die neue Tabelle (5)
-- -----------------------------------------------------------------------------
SELECT ok((SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'app.clearance_proposals'::regclass),
  'clearance_proposals: RLS ist an und erzwungen');
SELECT ok(NOT has_table_privilege('authenticated', 'app.clearance_proposals', 'SELECT'),
  'clearance_proposals: authenticated darf nicht direkt lesen, nur ueber rpc_get_clearance');
SELECT ok(NOT has_table_privilege('anon', 'app.clearance_proposals', 'SELECT'),
  'clearance_proposals: anon darf gar nichts');
SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'app.clearance_proposals'::regclass AND tgname = 'clearance_proposals_audit'),
  'clearance_proposals: der Audit Trigger haengt dran (Art. 9, Rechenschaftspflicht)');
SELECT ok(NOT has_function_privilege('authenticated', 'app.auth_target_is_team_player(uuid)', 'EXECUTE'),
  'der Helper aus Punkt 52 bleibt fuer authenticated zu');

-- -----------------------------------------------------------------------------
-- 9. Loeschpfad: der Vorschlag geht mit (Art. 17) (3)
-- -----------------------------------------------------------------------------
SELECT ok((SELECT count(*) FROM app.clearance_proposals WHERE person_id = 'b1000000-0000-0000-0000-000000000001') > 0,
  'Loeschpfad: vor dem Shred gibt es Vorschlaege ueber die Spielerin');
SELECT app._t31_jwt('e1000000-0000-0000-0000-000000000001','admin');
SELECT lives_ok($$SELECT app.rpc_shred_person('b1000000-0000-0000-0000-000000000001')$$, 'Loeschpfad laeuft');
SELECT is((SELECT count(*) FROM app.clearance_proposals WHERE person_id = 'b1000000-0000-0000-0000-000000000001'), 0::bigint,
  'Loeschpfad: nach dem Shred ist kein Vorschlag mehr da');

SELECT * FROM finish();
ROLLBACK;
