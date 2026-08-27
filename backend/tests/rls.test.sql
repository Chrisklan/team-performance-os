-- ============================================================================
-- Team Performance OS — tests/rls.test.sql (pgTAP)
--
-- Lauf:  psql -X -v ON_ERROR_STOP=1 -f tests/rls.test.sql tpos_rls_test
-- Erwartung: 0 failures, exit 0. Kein pg_prove noetig.
--
-- Testtechnik (Matrix 2):
--   SET LOCAL ROLE authenticated;
--   SET LOCAL request.jwt.claims = '{"sub":"<uuid>","role":"authenticated","app_role":"<rolle>"}';
-- Das ist der kanonische Supabase-RLS-Testweg. `authenticated` ist eine
-- normale Rolle ohne BYPASSRLS, deshalb greifen die Policies hier echt.
-- Die gesamte Suite laeuft in einer Transaktion, die am Ende zurueckgerollt
-- wird: die Seed-Daten hinterlassen nichts in der DB.
--
-- Seed-IDs (sprechend gewaehlt):
--   Spieler   P1 ...00a1  Max Muster      P2 ...00a2  Jonas Zweit
--   Profile   P1 ...00b1  P2 ...00b2
--             coach ...00c1  athletik ...00c2  physio ...00c3
--             arzt  ...00c4  admin    ...00c5
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;

SELECT plan(122);

-- ---------------------------------------------------------------------------
-- SEED (als Superuser, umgeht RLS bewusst)
-- ---------------------------------------------------------------------------

INSERT INTO players (id, first_name, last_name, birth_date, position, squad_number) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'Max',   'Muster', '2000-03-04', 'ST', 9),
  ('00000000-0000-0000-0000-0000000000a2', 'Jonas', 'Zweit',  '1998-11-12', 'IV', 4);

INSERT INTO profiles (id, full_name, email, role, player_id) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'Max Muster',    'max@club.test',   'player',   '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b2', 'Jonas Zweit',   'jonas@club.test', 'player',   '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000c1', 'Cheftrainer',   'coach@club.test', 'coach',    NULL),
  ('00000000-0000-0000-0000-0000000000c2', 'Athletik',      'athl@club.test',  'athletik', NULL),
  ('00000000-0000-0000-0000-0000000000c3', 'Physio',        'phys@club.test',  'physio',   NULL),
  ('00000000-0000-0000-0000-0000000000c4', 'Mannschaftsarzt','arzt@club.test', 'arzt',     NULL),
  ('00000000-0000-0000-0000-0000000000c5', 'Admin',         'admin@club.test', 'admin',    NULL);

-- Check-Ins: CK1 = P1 staff, CK2 = P1 med_only, CK3 = P2 med_only
INSERT INTO daily_checkins (id, player_id, checkin_date, sleep_hours, sleep_quality, soreness, mood, stress, energy, free_text, visibility_flag) VALUES
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a1', '2026-08-25', 7.5, 7, 3, 8, 3, 7, 'Wade zwickt leicht',   'staff'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000a1', '2026-08-24', 6.0, 5, 6, 5, 7, 4, 'Eigener Med-Text P1',  'med_only'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000a2', '2026-08-25', 8.0, 8, 2, 9, 2, 9, 'Fremder Med-Text P2',  'med_only');

INSERT INTO baselines (id, player_id, metric, mean_value, stddev_value, sample_count) VALUES
  ('00000000-0000-0000-0000-000000000ac1', '00000000-0000-0000-0000-0000000000a1', 'sleep_hours', 7.2000, 0.8000, 28),
  ('00000000-0000-0000-0000-000000000ac2', '00000000-0000-0000-0000-0000000000a2', 'sleep_hours', 7.9000, 0.5000, 28);

INSERT INTO readiness_scores (id, player_id, score_date, value, factors) VALUES
  ('00000000-0000-0000-0000-000000000ad1', '00000000-0000-0000-0000-0000000000a1', '2026-08-25', 72.50, '{"sleep":0.8,"soreness":0.6}'),
  ('00000000-0000-0000-0000-000000000ad2', '00000000-0000-0000-0000-0000000000a2', '2026-08-25', 88.00, '{"sleep":0.95,"soreness":0.9}');

INSERT INTO load_deviations (id, player_id, metric, deviation_pct, severity, factors, aggregate_label) VALUES
  ('00000000-0000-0000-0000-000000000ae1', '00000000-0000-0000-0000-0000000000a1', 'acwr', 34.20, 'watch',    '{"acute":420,"chronic":313}', 'erhoeht'),
  ('00000000-0000-0000-0000-000000000ae2', '00000000-0000-0000-0000-0000000000a2', 'acwr',  8.10, 'info',     '{"acute":390,"chronic":361}', 'normal');

INSERT INTO training_sessions (id, title, session_date, duration_min, session_type, planned_load, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'Aktivierung',   '2026-08-25', 75, 'field', 420.00, '00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-0000000000d2', 'Kraft Oberkoerper', '2026-08-26', 60, 'gym', 300.00, '00000000-0000-0000-0000-0000000000c2');

INSERT INTO session_loads (id, session_id, player_id, rpe, duration_min) VALUES
  ('00000000-0000-0000-0000-000000000af1', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 6, 75),
  ('00000000-0000-0000-0000-000000000af2', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a2', 5, 75);

INSERT INTO matches (id, opponent, match_date, home_away, competition, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000d5', 'FC Gegner', '2026-08-29', 'home', 'Bundesliga', '00000000-0000-0000-0000-0000000000c1');

INSERT INTO attendance (id, player_id, event_type, event_id, event_date, status, recorded_by) VALUES
  ('00000000-0000-0000-0000-000000000ab1', '00000000-0000-0000-0000-0000000000a1', 'training', '00000000-0000-0000-0000-0000000000d1', '2026-08-25', 'present', '00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-000000000ab2', '00000000-0000-0000-0000-0000000000a2', 'training', '00000000-0000-0000-0000-0000000000d1', '2026-08-25', 'late',    '00000000-0000-0000-0000-0000000000c1');

INSERT INTO development_goals (id, player_id, title, progress, status, created_by) VALUES
  ('00000000-0000-0000-0000-000000000a01', '00000000-0000-0000-0000-0000000000a1', 'Abschlussquote steigern', 30, 'in_progress', '00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-000000000a02', '00000000-0000-0000-0000-0000000000a2', 'Kopfballstaerke',         10, 'open',        '00000000-0000-0000-0000-0000000000c1');

-- Medical: zwei Records fuer P1 (alt/neu), einer fuer P2.
-- Der Badge in medical_status_view ist immer der aktuellste Record je Spieler.
INSERT INTO medical_records (id, player_id, record_date, category, diagnosis, symptoms, treatment, rehab_plan, clearance, visibility, author_profile_id, updated_at) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', '2026-08-01', 'assessment', 'unauffaellig',        'keine',              NULL,          NULL,        'green',  'med_only', '00000000-0000-0000-0000-0000000000c4', '2026-08-01 10:00:00+02'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000a1', '2026-08-20', 'injury',     'Muskelfaserriss M. soleus links', 'Druckschmerz Wade', 'Kryo, Entlastung', 'Reha Stufe 2', 'yellow', 'staff_status', '00000000-0000-0000-0000-0000000000c4', '2026-08-20 10:00:00+02'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000a2', '2026-08-20', 'illness',    'Infekt oberer Atemwege', 'Fieber',           'Ruhe',        NULL,        'red',    'med_only', '00000000-0000-0000-0000-0000000000c4', '2026-08-20 11:00:00+02');

INSERT INTO calendar_events (id, title, event_type, starts_at, ends_at, location, created_by) VALUES
  ('00000000-0000-0000-0000-000000000aa1', 'Teamsitzung', 'meeting', '2026-08-28 09:00:00+02', '2026-08-28 10:00:00+02', 'Videoraum', '00000000-0000-0000-0000-0000000000c1');

INSERT INTO messages (id, sender_profile_id, to_role, to_player_id, subject, body) VALUES
  ('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-0000000000c1', 'team',   NULL, 'Abfahrt', 'Bus faehrt 08:30.'),
  ('00000000-0000-0000-0000-000000000b02', '00000000-0000-0000-0000-0000000000c4', 'physio', NULL, 'Reha',    'Bitte Stufe 2 mit P1 starten.'),
  ('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-0000000000c1', NULL,     '00000000-0000-0000-0000-0000000000a1', 'Gespraech', 'Kurz nach dem Training bitte.');

INSERT INTO fines (id, player_id, reason, amount_cents, fine_date) VALUES
  ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-0000000000a1', 'Zu spaet zur Besprechung', 2500, '2026-08-24'),
  ('00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-0000000000a2', 'Handy in der Kabine',      1000, '2026-08-24');

INSERT INTO wearable_samples (id, player_id, source, sampled_at, metric, value) VALUES
  ('00000000-0000-0000-0000-000000000d01', '00000000-0000-0000-0000-0000000000a1', 'catapult', '2026-08-25 10:00:00+02', 'total_distance_m', 6120.0000),
  ('00000000-0000-0000-0000-000000000d02', '00000000-0000-0000-0000-0000000000a2', 'catapult', '2026-08-25 10:00:00+02', 'total_distance_m', 5880.0000);

INSERT INTO video_clips (id, player_id, match_id, title, url, created_by) VALUES
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-0000000000a1', NULL, 'Abschluss 1', 'https://video.test/1', '00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-0000000000a2', NULL, 'Kopfball 1',  'https://video.test/2', '00000000-0000-0000-0000-0000000000c1');

INSERT INTO access_log (id, viewer_profile_id, player_id, table_name, record_id, action) VALUES
  ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000a1', 'medical_records', '00000000-0000-0000-0000-0000000000f2', 'select'),
  ('00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000a2', 'medical_records', '00000000-0000-0000-0000-0000000000f3', 'select');


-- ===========================================================================
-- A. Helferfunktionen (Matrix 2)  — Tests 1-7
-- ===========================================================================

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';

SELECT is( current_app_role(), 'coach', 'A1  current_app_role() liest den app_role-Claim' );
SELECT is( current_profile_id(), '00000000-0000-0000-0000-0000000000c1'::uuid, 'A2  current_profile_id() liest den sub-Claim' );
SELECT is( current_player_id(), NULL::uuid, 'A3  current_player_id() ist NULL fuer Staff' );
SELECT is( is_medical_role(), false, 'A4  coach ist keine Med-Rolle' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( current_player_id(), '00000000-0000-0000-0000-0000000000a1'::uuid, 'A5  current_player_id() aufgeloest ueber profiles' );
SELECT is( is_staff(), false, 'A6  player ist kein Staff' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT is( is_medical_role(), true, 'A7  arzt ist Med-Rolle' );


-- ===========================================================================
-- B. MED-GATE (Fokus-Test)  — Tests 8-23
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM medical_records), 0::bigint,
           'B1  coach sieht KEINE einzige medical_records-Basiszeile' );
SELECT is( (SELECT count(*) FROM medical_status_view), 2::bigint,
           'B2  coach sieht den Status-Badge beider Spieler' );
SELECT is( (SELECT clearance FROM medical_status_view WHERE player_id = '00000000-0000-0000-0000-0000000000a1'), 'yellow',
           'B3  coach sieht den aktuellsten Clearance-Badge von P1' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated","app_role":"athletik"}';
SELECT is( (SELECT count(*) FROM medical_records), 0::bigint,
           'B4  athletik sieht KEINE einzige medical_records-Basiszeile' );
SELECT is( (SELECT count(*) FROM medical_status_view), 2::bigint,
           'B5  athletik sieht den Status-Badge beider Spieler' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT is( (SELECT count(*) FROM medical_records), 3::bigint, 'B6  arzt sieht alle medical_records' );
SELECT is( (SELECT diagnosis FROM medical_records WHERE id = '00000000-0000-0000-0000-0000000000f2'),
           'Muskelfaserriss M. soleus links', 'B7  arzt sieht die Diagnose im Klartext' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
SELECT is( (SELECT count(*) FROM medical_records), 3::bigint, 'B8  physio sieht alle medical_records' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM medical_records), 2::bigint,
           'B9  player sieht die eigenen medical_records voll (ADR-004)' );
SELECT is( (SELECT count(*) FROM medical_records WHERE player_id <> '00000000-0000-0000-0000-0000000000a1'), 0::bigint,
           'B10 player sieht KEINE fremden medical_records' );
SELECT is( (SELECT count(*) FROM medical_status_view), 1::bigint,
           'B11 player sieht nur den eigenen Status-Badge' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT is( (SELECT count(*) FROM medical_records), 3::bigint,
           'B12 admin hat vollen Lesezugriff auf medical_records (DONE_WHEN 6)' );

-- Schreibseite des Gates
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT throws_ok(
    $q$ INSERT INTO medical_records (player_id, diagnosis) VALUES ('00000000-0000-0000-0000-0000000000a1', 'coach-Diagnose') $q$,
    '42501'::char(5), NULL::text, 'B13 coach kann keinen medical_record anlegen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT throws_ok(
    $q$ INSERT INTO medical_records (player_id, diagnosis) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin-Diagnose') $q$,
    '42501'::char(5), NULL::text, 'B14 admin hat KEINEN medizinischen Schreibzugriff' );

WITH u AS (
    UPDATE medical_records SET clearance = 'green' WHERE id = '00000000-0000-0000-0000-0000000000f2' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 0::bigint, 'B15 admin kann keinen medical_record aendern' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT throws_ok(
    $q$ INSERT INTO medical_records (player_id, diagnosis) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Selbstdiagnose') $q$,
    '42501'::char(5), NULL::text, 'B16 player kann keinen medical_record anlegen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT lives_ok(
    $q$ INSERT INTO medical_records (player_id, diagnosis, clearance) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Verlaufskontrolle', 'orange') $q$,
    'B17 arzt legt medical_record an' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
WITH u AS (
    UPDATE medical_records SET rehab_plan = 'Reha Stufe 3' WHERE id = '00000000-0000-0000-0000-0000000000f2' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'B18 physio aktualisiert einen medical_record' );


-- ===========================================================================
-- C. OWN-DATA daily_checkins (Fokus-Test)  — Tests 26-29
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM daily_checkins), 2::bigint, 'C1  player P1 sieht nur die eigenen 2 Check-Ins' );
SELECT is( (SELECT count(*) FROM daily_checkins WHERE player_id = '00000000-0000-0000-0000-0000000000a2'), 0::bigint,
           'C2  player P1 sieht KEINEN Check-In von P2' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM daily_checkins), 1::bigint, 'C3  player P2 sieht nur den eigenen Check-In' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM daily_checkins), 3::bigint, 'C4  coach sieht alle Check-Ins (Zeilenebene)' );


-- ===========================================================================
-- D. FREE_TEXT-GATE (Fokus-Test)  — Tests 30-36
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e3'), NULL::text,
           'D1  coach sieht free_text = NULL bei visibility_flag = med_only' );
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e1'), 'Wade zwickt leicht',
           'D2  coach sieht free_text bei visibility_flag = staff' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated","app_role":"athletik"}';
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e3'), NULL::text,
           'D3  athletik sieht free_text = NULL bei med_only' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e3'), NULL::text,
           'D4  admin sieht free_text = NULL bei med_only' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e3'), 'Fremder Med-Text P2',
           'D5  arzt sieht free_text auch bei med_only' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT free_text FROM daily_checkins_staff WHERE id = '00000000-0000-0000-0000-0000000000e3'), 'Fremder Med-Text P2',
           'D6  player sieht den eigenen med_only-Freitext' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM daily_checkins_staff), 2::bigint,
           'D7  player sieht in daily_checkins_staff nur die eigenen Zeilen' );


-- ===========================================================================
-- E. WRITE-SCOPE (Fokus-Test)  — Tests 37-43
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT lives_ok(
    $q$ INSERT INTO daily_checkins (player_id, checkin_date, mood) VALUES ('00000000-0000-0000-0000-0000000000a1', '2026-08-26', 7) $q$,
    'E1  player schreibt den eigenen Check-In' );
SELECT throws_ok(
    $q$ INSERT INTO daily_checkins (player_id, checkin_date, mood) VALUES ('00000000-0000-0000-0000-0000000000a2', '2026-08-26', 7) $q$,
    '42501'::char(5), NULL::text, 'E2  player kann KEINEN fremden Check-In schreiben' );

WITH u AS (
    UPDATE daily_checkins SET mood = 1 WHERE id = '00000000-0000-0000-0000-0000000000e3' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 0::bigint, 'E3  player kann KEINEN fremden Check-In aendern' );

WITH u AS (
    UPDATE daily_checkins SET mood = 9 WHERE id = '00000000-0000-0000-0000-0000000000e1' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'E4  player aendert den eigenen Check-In' );

SELECT throws_ok(
    $q$ UPDATE daily_checkins SET player_id = '00000000-0000-0000-0000-0000000000a2' WHERE id = '00000000-0000-0000-0000-0000000000e1' $q$,
    '42501'::char(5), NULL::text, 'E5  player kann den eigenen Check-In nicht auf einen anderen Spieler umhaengen' );

SELECT lives_ok(
    $q$ INSERT INTO session_loads (session_id, player_id, rpe, duration_min) VALUES ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a1', 7, 60) $q$,
    'E6  player meldet den eigenen RPE' );
SELECT throws_ok(
    $q$ INSERT INTO session_loads (session_id, player_id, rpe, duration_min) VALUES ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', 7, 60) $q$,
    '42501'::char(5), NULL::text, 'E7  player kann KEINEN fremden RPE schreiben' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT throws_ok(
    $q$ INSERT INTO daily_checkins (player_id, checkin_date, mood) VALUES ('00000000-0000-0000-0000-0000000000a1', '2026-08-27', 7) $q$,
    '42501'::char(5), NULL::text, 'E8  coach kann keinen Check-In im Namen eines Spielers anlegen' );


-- ===========================================================================
-- F. WEARABLE (Fokus-Test)  — nur athletik + player(own)
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated","app_role":"athletik"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 2::bigint, 'F1  athletik sieht alle Wearable-Rohdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 0::bigint, 'F2  coach sieht KEINE Wearable-Rohdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 0::bigint, 'F3  physio sieht KEINE Wearable-Rohdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 0::bigint, 'F4  arzt sieht KEINE Wearable-Rohdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 1::bigint, 'F5  player sieht nur die eigenen Wearable-Rohdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT is( (SELECT count(*) FROM wearable_samples), 2::bigint, 'F6  admin sieht Wearable-Rohdaten (Audit)' );


-- ===========================================================================
-- G. profiles / players
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM profiles), 1::bigint, 'G1  player sieht nur das eigene Profil' );
SELECT is( (SELECT count(*) FROM players), 1::bigint, 'G2  player sieht nur die eigenen Stammdaten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM profiles), 7::bigint, 'G3  coach sieht alle Profile (Namen/Rollen)' );
SELECT is( (SELECT count(*) FROM players), 2::bigint, 'G4  coach sieht alle Spieler-Stammdaten' );
SELECT throws_ok(
    $q$ INSERT INTO players (first_name, last_name) VALUES ('Neuer', 'Spieler') $q$,
    '42501'::char(5), NULL::text, 'G5  coach kann keinen Spieler anlegen' );
SELECT throws_ok(
    $q$ INSERT INTO profiles (id, full_name, role) VALUES (gen_random_uuid(), 'Schatten-Admin', 'admin') $q$,
    '42501'::char(5), NULL::text, 'G6  coach kann kein Profil anlegen (keine Rollen-Eskalation)' );

WITH u AS (
    UPDATE profiles SET role = 'admin' WHERE id = '00000000-0000-0000-0000-0000000000c1' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 0::bigint, 'G7  coach kann die eigene Rolle nicht hochstufen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT lives_ok(
    $q$ INSERT INTO players (first_name, last_name) VALUES ('Neuer', 'Spieler') $q$,
    'G8  admin legt einen Spieler an' );

WITH u AS (
    UPDATE players SET position = 'LV' WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'G9  admin pflegt Spieler-Stammdaten' );

WITH u AS (
    UPDATE profiles SET role = 'athletik' WHERE id = '00000000-0000-0000-0000-0000000000c1' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'G10 admin verwaltet Rollen' );


-- ===========================================================================
-- H. Training & Wettkampf
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM training_sessions), 2::bigint, 'H1  player liest den Trainingsplan' );
SELECT is( (SELECT count(*) FROM matches), 1::bigint, 'H2  player liest den Spielplan' );
SELECT is( (SELECT count(*) FROM calendar_events), 1::bigint, 'H3  player liest den Teamkalender' );
SELECT throws_ok(
    $q$ INSERT INTO training_sessions (title, session_date) VALUES ('Wunschtraining', '2026-08-30') $q$,
    '42501'::char(5), NULL::text, 'H4  player kann kein Training planen' );
SELECT throws_ok(
    $q$ INSERT INTO calendar_events (title, starts_at) VALUES ('Privattermin', '2026-08-30 09:00:00+02') $q$,
    '42501'::char(5), NULL::text, 'H5  player kann keinen Kalendereintrag anlegen' );

SELECT is( (SELECT count(*) FROM session_loads), 2::bigint, 'H6  player sieht nur die eigenen RPE-Werte' );
SELECT is( (SELECT count(*) FROM attendance), 1::bigint, 'H7  player sieht nur die eigene Anwesenheit' );
SELECT is( (SELECT count(*) FROM development_goals), 1::bigint, 'H8  player sieht nur das eigene Entwicklungsziel' );

WITH u AS (
    UPDATE development_goals SET self_assessment = 'laeuft gut', progress = 45
    WHERE id = '00000000-0000-0000-0000-000000000a01' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'H9  player bewertet das eigene Entwicklungsziel' );

WITH u AS (
    UPDATE development_goals SET progress = 99 WHERE id = '00000000-0000-0000-0000-000000000a02' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 0::bigint, 'H10 player kann kein fremdes Entwicklungsziel aendern' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM session_loads), 3::bigint, 'H11 coach sieht alle RPE-Werte' );
SELECT is( (SELECT count(*) FROM attendance), 2::bigint, 'H12 coach sieht die gesamte Anwesenheit' );
SELECT is( (SELECT count(*) FROM development_goals), 2::bigint, 'H13 coach sieht alle Entwicklungsziele' );
SELECT lives_ok(
    $q$ INSERT INTO training_sessions (title, session_date, session_type) VALUES ('Abschlusstraining', '2026-08-28', 'tactical') $q$,
    'H14 coach plant ein Training' );
SELECT lives_ok(
    $q$ INSERT INTO attendance (player_id, event_type, event_date, status) VALUES ('00000000-0000-0000-0000-0000000000a1', 'meeting', '2026-08-28', 'present') $q$,
    'H15 coach erfasst Anwesenheit' );
SELECT lives_ok(
    $q$ INSERT INTO calendar_events (title, starts_at) VALUES ('Videoanalyse', '2026-08-28 14:00:00+02') $q$,
    'H16 coach plant einen Termin' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated","app_role":"athletik"}';
WITH u AS (
    UPDATE matches SET result = '2:1' WHERE id = '00000000-0000-0000-0000-0000000000d5' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 1::bigint, 'H17 athletik pflegt das Spiel' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
SELECT throws_ok(
    $q$ INSERT INTO training_sessions (title, session_date) VALUES ('Reha-Einheit', '2026-08-30') $q$,
    '42501'::char(5), NULL::text, 'H18 physio kann kein Training planen' );

WITH u AS (
    UPDATE attendance SET status = 'excused' WHERE id = '00000000-0000-0000-0000-000000000ab1' RETURNING 1
)
SELECT is( (SELECT count(*) FROM u), 0::bigint, 'H19 physio kann keine Anwesenheit setzen' );


-- ===========================================================================
-- I. Baselines / Readiness / LoadDeviations (ADR-005)
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM baselines), 1::bigint, 'I1  player sieht nur die eigene Baseline' );
SELECT is( (SELECT count(*) FROM readiness_scores), 1::bigint, 'I2  player sieht nur den eigenen Readiness-Score' );
SELECT is( (SELECT count(*) FROM load_deviations), 1::bigint, 'I3  player sieht nur die eigene Load-Deviation' );
SELECT throws_ok(
    $q$ INSERT INTO readiness_scores (player_id, score_date, value) VALUES ('00000000-0000-0000-0000-0000000000a1', '2026-08-26', 99) $q$,
    '42501'::char(5), NULL::text, 'I4  player kann keinen Readiness-Score schreiben' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM baselines), 2::bigint, 'I5  coach sieht alle Baselines' );
SELECT is( (SELECT count(*) FROM readiness_scores), 2::bigint, 'I6  coach sieht alle Readiness-Scores' );
SELECT is( (SELECT count(*) FROM load_deviations), 2::bigint, 'I7  coach sieht alle Load-Deviations' );
SELECT throws_ok(
    $q$ INSERT INTO load_deviations (player_id, metric, deviation_pct) VALUES ('00000000-0000-0000-0000-0000000000a1', 'acwr', 50) $q$,
    '42501'::char(5), NULL::text, 'I8  coach kann keine Load-Deviation schreiben (nur Service-Role)' );
SELECT throws_ok(
    $q$ INSERT INTO baselines (player_id, metric) VALUES ('00000000-0000-0000-0000-0000000000a1', 'hrv') $q$,
    '42501'::char(5), NULL::text, 'I9  coach kann keine Baseline schreiben (nur Service-Role)' );


-- ===========================================================================
-- J. Kommunikation / Disziplin
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM messages), 2::bigint, 'J1  player P1 sieht Team-Nachricht + direkte Nachricht' );
SELECT is( (SELECT count(*) FROM messages WHERE id = '00000000-0000-0000-0000-000000000b02'), 0::bigint,
           'J2  player sieht KEINE Nachricht an die Rollen-Gruppe physio' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM messages), 1::bigint, 'J3  player P2 sieht nur die Team-Nachricht' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
SELECT is( (SELECT count(*) FROM messages), 2::bigint, 'J4  physio sieht Team-Nachricht + Nachricht an die Rolle physio' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT is( (SELECT count(*) FROM messages), 3::bigint, 'J5  admin sieht alle Nachrichten (Audit)' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT throws_ok(
    $q$ INSERT INTO messages (sender_profile_id, to_role, body) VALUES ('00000000-0000-0000-0000-0000000000b1', 'team', 'Hallo Team') $q$,
    '42501'::char(5), NULL::text, 'J6  player kann keine Nachricht senden' );
SELECT is( (SELECT count(*) FROM fines), 1::bigint, 'J7  player sieht nur die eigenen Strafen' );
SELECT throws_ok(
    $q$ INSERT INTO fines (player_id, reason, amount_cents) VALUES ('00000000-0000-0000-0000-0000000000a2', 'Rache', 9900) $q$,
    '42501'::char(5), NULL::text, 'J8  player kann keine Strafe verhaengen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT lives_ok(
    $q$ INSERT INTO messages (sender_profile_id, to_role, body) VALUES ('00000000-0000-0000-0000-0000000000c4', 'coach', 'Belastungsfreigabe erteilt') $q$,
    'J9  arzt sendet eine Nachricht an die Rollen-Gruppe coach' );
SELECT throws_ok(
    $q$ INSERT INTO messages (sender_profile_id, to_role, body) VALUES ('00000000-0000-0000-0000-0000000000c1', 'team', 'Im Namen des Trainers') $q$,
    '42501'::char(5), NULL::text, 'J10 arzt kann keine Nachricht im Namen eines anderen senden' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM fines), 2::bigint, 'J11 coach sieht alle Strafen' );
SELECT lives_ok(
    $q$ INSERT INTO fines (player_id, reason, amount_cents) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Verspaetung', 2500) $q$,
    'J12 coach verhaengt eine Strafe' );


-- ===========================================================================
-- K. video_clips
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM video_clips), 1::bigint, 'K1  player sieht nur die eigenen Clips' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated","app_role":"physio"}';
SELECT is( (SELECT count(*) FROM video_clips), 2::bigint, 'K2  physio sieht alle Clips' );
SELECT throws_ok(
    $q$ INSERT INTO video_clips (title, url) VALUES ('Reha-Clip', 'https://video.test/3') $q$,
    '42501'::char(5), NULL::text, 'K3  physio kann keinen Clip anlegen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT lives_ok(
    $q$ INSERT INTO video_clips (title, url) VALUES ('Standards', 'https://video.test/4') $q$,
    'K4  coach legt einen Clip an' );


-- ===========================================================================
-- L. Audit / Portabilitaet (ADR-004, Matrix 5)
-- ===========================================================================

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT is( (SELECT count(*) FROM access_log), 1::bigint, 'L1  player sieht nur die Zugriffe auf die eigenen Daten' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT is( (SELECT count(*) FROM access_log), 0::bigint, 'L2  coach hat KEINEN Zugriff auf das Audit-Log' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated","app_role":"arzt"}';
SELECT is( (SELECT count(*) FROM access_log), 0::bigint, 'L3  arzt hat KEINEN Zugriff auf das Audit-Log' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT is( (SELECT count(*) FROM access_log), 2::bigint, 'L4  admin auditiert das gesamte Log' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","app_role":"player"}';
SELECT throws_ok(
    $q$ INSERT INTO access_log (player_id, table_name, action) VALUES ('00000000-0000-0000-0000-0000000000a1', 'medical_records', 'select') $q$,
    '42501'::char(5), NULL::text, 'L5  niemand schreibt direkt ins Audit-Log (nur log_access)' );

SELECT isnt( log_access('00000000-0000-0000-0000-0000000000a1', 'unit_test_probe', NULL, 'select'), NULL::uuid,
             'L6  log_access() schreibt als SECURITY DEFINER ins Audit-Log' );
SELECT is( (SELECT count(*) FROM access_log WHERE table_name = 'unit_test_probe'), 1::bigint,
           'L7  der via log_access geschriebene Eintrag ist fuer den Spieler sichtbar' );

SELECT is( data_portability_export('00000000-0000-0000-0000-0000000000a1') -> 'player' ->> 'id',
           '00000000-0000-0000-0000-0000000000a1',
           'L8  player exportiert die eigenen Daten (Art. 20 DSGVO)' );
SELECT is( jsonb_array_length(data_portability_export('00000000-0000-0000-0000-0000000000a1') -> 'medical_records') > 0, true,
           'L9  der Export enthaelt die eigenen medizinischen Daten' );
SELECT throws_ok(
    $q$ SELECT data_portability_export('00000000-0000-0000-0000-0000000000a2') $q$,
    '42501'::char(5), NULL::text, 'L10 player kann KEINE fremden Daten exportieren' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated","app_role":"coach"}';
SELECT throws_ok(
    $q$ SELECT data_portability_export('00000000-0000-0000-0000-0000000000a1') $q$,
    '42501'::char(5), NULL::text, 'L11 coach kann keinen Portabilitaets-Export ausloesen' );

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated","app_role":"admin"}';
SELECT lives_ok(
    $q$ SELECT data_portability_export('00000000-0000-0000-0000-0000000000a1') $q$,
    'L12 admin loest den Portabilitaets-Export aus' );


-- ===========================================================================
-- M. Struktur: RLS wirklich scharf, Policies vorhanden
-- ===========================================================================

RESET ROLE;

SELECT is(
    (SELECT count(*)::int
       FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind = 'r'
        AND c.relrowsecurity
        AND c.relname = ANY (ARRAY[
            'profiles', 'players', 'daily_checkins', 'baselines', 'readiness_scores',
            'load_deviations', 'training_sessions', 'session_loads', 'matches',
            'attendance', 'development_goals', 'medical_records', 'calendar_events',
            'messages', 'fines', 'wearable_samples', 'video_clips', 'access_log'])),
    18,
    'M1  alle 18 Tabellen der Matrix haben ROW LEVEL SECURITY aktiviert' );

SELECT is(
    (SELECT count(DISTINCT tablename)::int
       FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = ANY (ARRAY[
            'profiles', 'players', 'daily_checkins', 'baselines', 'readiness_scores',
            'load_deviations', 'training_sessions', 'session_loads', 'matches',
            'attendance', 'development_goals', 'medical_records', 'calendar_events',
            'messages', 'fines', 'wearable_samples', 'video_clips', 'access_log'])),
    18,
    'M2  jede der 18 Tabellen hat mindestens eine Policy' );

SELECT is(
    (SELECT count(*)::int FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'access_log' AND cmd <> 'SELECT'),
    0,
    'M3  access_log hat ausser SELECT keine Policy (Schreibpfad nur via log_access)' );

SELECT is(
    (SELECT count(*)::int FROM pg_policies WHERE schemaname = 'public' AND cmd = 'DELETE'),
    0,
    'M4  keine DELETE-Policy: Loeschen laeuft ausschliesslich ueber die Service-Role' );

SELECT is(
    (SELECT count(*)::int FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.prosecdef
        AND p.proname IN ('current_app_role', 'current_profile_id', 'current_player_id',
                          'is_medical_role', 'is_staff', 'log_access', 'data_portability_export')),
    7,
    'M5  alle sieben Helfer- und Audit-Funktionen sind SECURITY DEFINER' );

SELECT is(
    (SELECT count(*)::int FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND c.relname IN ('medical_status_view', 'daily_checkins_staff')
        AND NOT coalesce((SELECT option_value::boolean FROM pg_options_to_table(c.reloptions)
                           WHERE option_name = 'security_invoker'), false)),
    2,
    'M6  beide Gate-Views laufen als Security-Definer-Views' );


SELECT * FROM finish();

ROLLBACK;
