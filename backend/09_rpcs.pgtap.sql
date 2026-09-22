-- =============================================================================
-- 09_rpcs.pgtap.sql — Tests für alle 11 RPCs aus 09_rpcs.sql
-- Verwendet pgtap 1.3.x (ohne _ensure_schema)
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;

SELECT no_plan();

-- =============================================================================
-- TEST-DB SETUP
-- =============================================================================

INSERT INTO app.teams (id, name, timezone) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Test Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id) VALUES
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Admin User', 'admin', '22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'Coach User', 'coach', '33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'Physio User', 'physio', '44444444-4444-4444-4444-444444444444'),
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', 'Doctor User', 'doctor', '55555555-5555-5555-5555-555555555555'),
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111', 'Player User', 'player', '66666666-6666-6666-6666-666666666666');

INSERT INTO app.role_assignments (team_id, person_id, role) VALUES
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'admin'),
  ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', 'coach'),
  ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444', 'physio'),
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'doctor'),
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'player');

INSERT INTO app.daily_checkins (id, team_id, person_id, date, body_map) VALUES
  ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', '{"region": "knee", "value": 3}'::jsonb);

INSERT INTO app.readiness_scores (id, team_id, person_id, date, score_total, band, factors) VALUES
  ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 85.5, 'high', '{"sleep": 8.0}'::jsonb);

INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 15.5, 'unreviewed');

INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'limited', 'max 60 min', '2026-09-01', '55555555-5555-5555-5555-555555555555', 'doctor');


-- =============================================================================
-- JWT HELPER
-- =============================================================================

CREATE OR REPLACE FUNCTION app._test_set_jwt(jsonb) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', $1::text, true);
$$;


-- =============================================================================
-- POSITIVE TESTS (rpc_get_my_roles als Admin)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_admin_denials('2026-09-01', '2026-09-30')$$, 'rpc_admin_denials als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_shred_person('66666666-6666-6666-6666-666666666666')$$, 'rpc_shred_person als Admin');
SELECT lives_ok($$SELECT * FROM app.rpc_export_my_data()$$, 'rpc_export_my_data als Admin');

-- Zuruecksetzen (nach shred sind Daten weg, also neu setzen).
-- Seit AP-39b raeumt rpc_shred_person v2 alle Speicherorte der Person, nicht mehr
-- nur app.persons. Die Fixtures fuer Check-In, Score und Lastabweichung kommen
-- deshalb hier ebenfalls zurueck.
SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id) VALUES
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111', 'Player User', 'player', '66666666-6666-6666-6666-666666666666')
ON CONFLICT (id) DO UPDATE SET is_active = true, display_name = 'Player User', auth_user_id = '66666666-6666-6666-6666-666666666666', birth_date = NULL, updated_at = now();

INSERT INTO app.medical_clearances (team_id, person_id, status, load_note, valid_from, set_by, set_by_role) VALUES
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'limited', 'max 60 min', '2026-09-01', '55555555-5555-5555-5555-555555555555', 'doctor')
ON CONFLICT DO NOTHING;

INSERT INTO app.daily_checkins (id, team_id, person_id, date, body_map) VALUES
  ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', '{"region": "knee", "value": 3}'::jsonb)
ON CONFLICT DO NOTHING;

INSERT INTO app.readiness_scores (id, team_id, person_id, date, score_total, band, factors) VALUES
  ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 85.5, 'high', '{"sleep": 8.0}'::jsonb)
ON CONFLICT DO NOTHING;

INSERT INTO app.load_deviations (id, team_id, person_id, date, deviation, state) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', '2026-09-01', 15.5, 'unreviewed')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- POSITIVE TESTS (Coach)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Coach');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Coach');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Coach');

-- =============================================================================
-- POSITIVE TESTS (Physio)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_propose_clearance('66666666-6666-6666-6666-666666666666', 'limited', 'nur individuell')$$, 'rpc_propose_clearance als Physio');
SELECT lives_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'release')$$, 'rpc_release_deviation als Physio');

-- =============================================================================
-- POSITIVE TESTS (Doctor)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated","app_role":"doctor","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_list_team_members()$$, 'rpc_list_team_members als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', 'voll belastbar', '2026-09-03', NULL)$$, 'rpc_set_clearance als Doctor');
SELECT lives_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'dismiss')$$, 'rpc_release_deviation als Doctor');

-- =============================================================================
-- POSITIVE TESTS (Player)
-- =============================================================================

SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_roles()$$, 'rpc_get_my_roles als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, 'rpc_check_ins_medical als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, 'rpc_readiness_full als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$, 'rpc_get_clearance als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_get_my_access_log('2026-09-01', '2026-09-30')$$, 'rpc_get_my_access_log als Player');
SELECT lives_ok($$SELECT * FROM app.rpc_export_my_data()$$, 'rpc_export_my_data als Player');


-- =============================================================================
-- NEGATIVE TESTS (FORBIDDEN 42501)
-- =============================================================================

-- Coach darf body_map nicht
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_check_ins_medical('2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: daily_checkins.body_map', 'rpc_check_ins_medical blockt Coach');

-- Coach darf readiness_full nicht
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: readiness_scores.score_total', 'rpc_readiness_full blockt Coach');

-- Coach darf Clearance nicht setzen
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL, '2026-09-03', NULL)$$, '42501', 'FORBIDDEN: medical_clearances.set (only doctor)', 'rpc_set_clearance blockt Coach');

-- Physio darf nicht setzen
SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL, '2026-09-03', NULL)$$, '42501', 'FORBIDDEN: medical_clearances.set (only doctor)', 'rpc_set_clearance blockt Physio');

-- Player darf Liste nicht sehen
SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_list_team_members()$$, '42501', 'FORBIDDEN: persons.list', 'rpc_list_team_members blockt Player');

-- Player darf nicht freigeben
SELECT app._test_set_jwt('{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated","app_role":"player","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_release_deviation('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'release')$$, '42501', 'FORBIDDEN: load_deviations.release', 'rpc_release_deviation blockt Player');

-- Coach darf nicht shredden
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_shred_person('66666666-6666-6666-6666-666666666666')$$, '42501', 'FORBIDDEN: persons.shred (only admin)', 'rpc_shred_person blockt Coach');

-- Coach darf Admin-Denials nicht sehen
SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok($$SELECT * FROM app.rpc_admin_denials('2026-09-01', '2026-09-30')$$, '42501', 'FORBIDDEN: access_denials.admin', 'rpc_admin_denials blockt Coach');


-- =============================================================================
-- AUDIT LOG TEST
-- =============================================================================

SELECT ok((SELECT count(*) > 0 FROM app.audit_log), 'audit_log hat Eintraege');
SELECT ok((SELECT count(*) > 0 FROM app.access_log), 'access_log hat Eintraege');


-- =============================================================================
-- VOCABULARY CHECK (kein verbotenes Vokabular)
-- =============================================================================

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'app' AND (p.proname LIKE '%tenant%' OR p.proname LIKE '%player_id%')),
  'Keine verbotenen Funktionsnamen'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'app' AND c.relkind = 'r' AND (c.relname LIKE '%tenant%' OR c.relname IN ('players'))),
  'Keine verbotenen Tabellennamen'
);



-- =============================================================================
-- PUNKT 53 / ADR-018: admin liest die Freigabe, Status UND Freitext
-- =============================================================================
--
-- Befund N2 der Gegenlesung war: der Waechter laesst admin durch, die Matrix sagte
-- '-'. Chris hat am 2026-09-22 die Matrix geaendert statt den Code und es begruendet
-- (ADR-018: Kaderplanung, Verbandsmeldung, Vertretung ohne Arzt). Diese Tests halten
-- die Entscheidung fest. Wer sie kippen sieht, hat entweder ADR-018 zurueckgenommen
-- oder versehentlich den admin Zweig entfernt.
--
-- GRENZE, die zur Entscheidung gehoert: entschieden ist die Rolle `admin`, wie sie
-- heute existiert. Eine spaeter eingefuehrte, eingeschraenkte Verwaltungsrolle erbt
-- das Recht NICHT und braucht eine eigene Entscheidung.

SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');

SELECT lives_ok(
  $$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$,
  'ADR-018: rpc_get_clearance laeuft fuer admin');
CREATE TEMP TABLE _adr018_admin AS
  SELECT status::text AS st, load_note AS note
    FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666');

SELECT isnt((SELECT st   FROM _adr018_admin), NULL, 'ADR-018: admin sieht den Status der Freigabe');
SELECT isnt((SELECT note FROM _adr018_admin), NULL, 'ADR-018: admin sieht auch den Freitext load_note, nicht nur die Einstufung');

-- Die eigentliche Aussage von ADR-018, Umfang "Status UND Freitext": admin bekommt
-- dasselbe zu sehen wie die Medizin, nichts ist geschwaerzt. Der Vergleich ist
-- unabhaengig davon, welche Freigabe an dieser Stelle der Suite gerade die juengste
-- ist -- ein fester Erwartungswert waere hier an fruehere Tests gekoppelt.
SELECT app._test_set_jwt('{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated","app_role":"doctor","team_id":"11111111-1111-1111-1111-111111111111"}');
CREATE TEMP TABLE _adr018_doctor AS
  SELECT status::text AS st, load_note AS note
    FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666');

SELECT is((SELECT st   FROM _adr018_admin), (SELECT st   FROM _adr018_doctor),
  'ADR-018: admin sieht denselben Status wie die Aerztin');
SELECT is((SELECT note FROM _adr018_admin), (SELECT note FROM _adr018_doctor),
  'ADR-018: admin sieht denselben Freitext wie die Aerztin, nichts geschwaerzt');

SELECT app._test_set_jwt('{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated","app_role":"admin","team_id":"11111111-1111-1111-1111-111111111111"}');

-- Die Grenze der Entscheidung: lesen ja, setzen nein.
SELECT throws_ok(
  $$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL, '2026-09-03', NULL)$$,
  '42501', 'FORBIDDEN: medical_clearances.set (only doctor)',
  'ADR-018 aendert nur die Lesezeile: admin darf die Freigabe weiterhin NICHT setzen');
SELECT throws_ok(
  $$SELECT * FROM app.rpc_propose_clearance('66666666-6666-6666-6666-666666666666', 'full', NULL)$$,
  '42501', 'FORBIDDEN: medical_clearances.propose (only physio)',
  'ADR-018 aendert nur die Lesezeile: admin darf die Freigabe auch nicht vorschlagen');

-- Der COMMENT ist die einzige Stelle, an der die Begruendung im Code steht.
-- Lessons Learned AP-56: ein pauschales Ueberschreiben nimmt sie weg.
SELECT ok(
  obj_description('app.rpc_get_clearance(uuid)'::regprocedure, 'pg_proc') LIKE '%ADR-018%',
  'ADR-018: der COMMENT der Funktion nennt das ADR, der admin Zweig ist als begruendet markiert');


-- =============================================================================
-- PUNKT 52 UND 56 (Befunde N3, N4, N8): Teampruefung vor den Schreibstellen
-- =============================================================================
--
-- Was hier NICHT geprueft werden kann: dass nach einer Ablehnung nichts in
-- app.access_log oder app.medical_clearances stehen BLEIBT. throws_ok laeuft in
-- einem eigenen Savepoint, die Suite rollt am Ende zurueck, ein "nichts gewachsen"
-- waere hier wertlos (Lessons Learned, F1). Diese Haelfte ist im Autocommit-Klon
-- mit zwei Teams gemessen, je Aussage ein eigener psql -f Lauf, und zwar gegen
-- beide Staende: Audit 2026-09-21, Abschnitt 14.
--
-- Die Suite prueft die andere Haelfte: dass die Ablehnung ueberhaupt kommt, dass
-- die erlaubten Wege unveraendert durchgehen, und dass der erlaubte Weg von
-- rpc_propose_clearance genau eine Protokollzeile schreibt.

-- Zweites Team, damit "teamfremd" ueberhaupt gemessen werden kann.
INSERT INTO app.teams (id, name, timezone) VALUES
  ('a2222222-2222-2222-2222-222222222222', 'Test Team A2', 'Europe/Berlin');
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id) VALUES
  ('b2222222-2222-2222-2222-222222222222', 'a2222222-2222-2222-2222-222222222222', 'Player A2', 'player', 'b2222222-2222-2222-2222-222222222222');
INSERT INTO app.role_assignments (team_id, person_id, role) VALUES
  ('a2222222-2222-2222-2222-222222222222', 'b2222222-2222-2222-2222-222222222222', 'player');


-- --- Der Helper einzeln -------------------------------------------------------

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');

SELECT ok(app.auth_target_is_team_player('66666666-6666-6666-6666-666666666666'),
  'Helper: aktive Spielerin des eigenen Teams ist wahr');
SELECT ok(NOT app.auth_target_is_team_player('b2222222-2222-2222-2222-222222222222'),
  'Helper: Spielerin eines fremden Teams ist falsch');
SELECT ok(NOT app.auth_target_is_team_player(NULL),
  'Helper: NULL ist falsch, nicht NULL');
SELECT ok(NOT app.auth_target_is_team_player('00000000-0000-0000-0000-000000000000'),
  'Helper: unbekannte Id ist falsch');
SELECT ok(NOT app.auth_target_is_team_player('33333333-3333-3333-3333-333333333333'),
  'Helper: eigenes Team, aber keine Spielerin (Coach) ist falsch');

UPDATE app.persons SET is_active = false WHERE id = '66666666-6666-6666-6666-666666666666';
SELECT ok(NOT app.auth_target_is_team_player('66666666-6666-6666-6666-666666666666'),
  'Helper: deaktivierte Spielerin des eigenen Teams ist falsch');
UPDATE app.persons SET is_active = true WHERE id = '66666666-6666-6666-6666-666666666666';

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"a2222222-2222-2222-2222-222222222222"}');
SELECT ok(NOT app.auth_target_is_team_player('66666666-6666-6666-6666-666666666666'),
  'Helper: falscher team_id Claim bestaetigt kein Team, also falsch');

SELECT ok(NOT has_function_privilege('authenticated', 'app.auth_target_is_team_player(uuid)', 'EXECUTE'),
  'Helper: kein EXECUTE fuer authenticated');
SELECT ok(NOT has_function_privilege('anon', 'app.auth_target_is_team_player(uuid)', 'EXECUTE'),
  'Helper: kein EXECUTE fuer anon');


-- --- N3: Protokollzeile ueber eine teamfremde Person ---------------------------

SELECT app._test_set_jwt('{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated","app_role":"coach","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok(
  $$SELECT * FROM app.rpc_get_clearance('b2222222-2222-2222-2222-222222222222')$$,
  '42501', 'FORBIDDEN: medical_clearances.get',
  'Punkt 52 (N3): rpc_get_clearance blockt eine teamfremde Person');
SELECT lives_ok(
  $$SELECT * FROM app.rpc_get_clearance('66666666-6666-6666-6666-666666666666')$$,
  'Positivkontrolle: rpc_get_clearance laeuft fuer die eigene Spielerin unveraendert');

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok(
  $$SELECT * FROM app.rpc_readiness_full('b2222222-2222-2222-2222-222222222222', '2026-09-01', '2026-09-30')$$,
  '42501', 'FORBIDDEN: readiness_scores.full',
  'Punkt 52 (N3): rpc_readiness_full blockt eine teamfremde Person');
SELECT lives_ok(
  $$SELECT * FROM app.rpc_readiness_full('66666666-6666-6666-6666-666666666666', '2026-09-01', '2026-09-30')$$,
  'Positivkontrolle: rpc_readiness_full laeuft fuer die eigene Spielerin unveraendert');


-- --- N4: Freigabe fuer eine teamfremde Person ---------------------------------

SELECT app._test_set_jwt('{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated","app_role":"doctor","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok(
  $$SELECT * FROM app.rpc_set_clearance('b2222222-2222-2222-2222-222222222222', 'blocked', 'quer', '2026-09-03', NULL)$$,
  '42501', 'FORBIDDEN: medical_clearances.set',
  'Punkt 52 (N4): rpc_set_clearance blockt eine teamfremde Person');
SELECT lives_ok(
  $$SELECT * FROM app.rpc_set_clearance('66666666-6666-6666-6666-666666666666', 'full', 'eigen', '2026-09-03', NULL)$$,
  'Positivkontrolle: rpc_set_clearance laeuft fuer die eigene Spielerin unveraendert');


-- --- Punkt 56: dieselbe Luecke in rpc_propose_clearance, und die Protokollzeile

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT throws_ok(
  $$SELECT * FROM app.rpc_propose_clearance('b2222222-2222-2222-2222-222222222222', 'individual', 'quer')$$,
  '42501', 'FORBIDDEN: medical_clearances.propose',
  'Punkt 56: rpc_propose_clearance blockt eine teamfremde Person');

CREATE TEMP TABLE _n8_vorher AS
  SELECT (SELECT count(*) FROM app.access_log)         AS log,
         (SELECT count(*) FROM app.medical_clearances) AS clr;

SELECT lives_ok(
  $$SELECT * FROM app.rpc_propose_clearance('66666666-6666-6666-6666-666666666666', 'individual', 'Vorschlag Physio')$$,
  'Positivkontrolle: rpc_propose_clearance laeuft fuer die eigene Spielerin unveraendert');

SELECT is((SELECT count(*) FROM app.medical_clearances) - (SELECT clr FROM _n8_vorher), 1::bigint,
  'rpc_propose_clearance schreibt weiterhin genau eine Zeile in medical_clearances');
SELECT is((SELECT count(*) FROM app.access_log) - (SELECT log FROM _n8_vorher), 1::bigint,
  'Punkt 56 (N8): rpc_propose_clearance schreibt jetzt genau eine Zeile in access_log');
SELECT is((SELECT action FROM app.access_log ORDER BY id DESC LIMIT 1), 'write',
  'Punkt 56 (N8): die neue Zeile traegt action = write, wie bei rpc_set_clearance');
SELECT is((SELECT actor_role::text FROM app.access_log ORDER BY id DESC LIMIT 1), 'physio',
  'Punkt 56 (N8): die neue Zeile traegt actor_role = physio, Vorschlag und Entscheidung bleiben unterscheidbar');
SELECT is((SELECT subject_id FROM app.access_log ORDER BY id DESC LIMIT 1),
  '66666666-6666-6666-6666-666666666666'::uuid,
  'Punkt 56 (N8): die neue Zeile nennt die Spielerin als subject_id');


-- --- Kein Auseinanderlaufen der beiden Fassungen ------------------------------
--
-- app.rpc_body_map_region_reports traegt ihr Praedikat eingebaut (20_denial_answer.sql),
-- die vier Funktionen aus Punkt 52 und 56 nutzen den Helper. Beide muessen dieselbe
-- Antwort geben. Der Test ist verhaltensbasiert: als Physio faellt bei region_reports
-- jeder andere Ablehnungsgrund weg, uebrig bleibt genau die Personenpruefung.

SELECT app._test_set_jwt('{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated","app_role":"physio","team_id":"11111111-1111-1111-1111-111111111111"}');
SELECT is(
  (SELECT count(*) FROM (VALUES
      ('66666666-6666-6666-6666-666666666666'::uuid),
      ('b2222222-2222-2222-2222-222222222222'::uuid),
      ('33333333-3333-3333-3333-333333333333'::uuid),
      ('00000000-0000-0000-0000-000000000000'::uuid),
      (NULL::uuid)) v(pid)
    WHERE app.is_denial(app.rpc_body_map_region_reports(v.pid, 28))
          IS DISTINCT FROM (NOT app.auth_target_is_team_player(v.pid))),
  0::bigint,
  'Helper und das eingebaute Praedikat in rpc_body_map_region_reports entscheiden gleich');


SELECT finish();
