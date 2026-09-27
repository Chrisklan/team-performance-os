-- =============================================================================
-- 38_training_load.pgtap.sql — Trainingsplanung (Modul 6, AP-68)
--
-- Prueft backend/38_training_load.sql: Struktur (app_session_type,
-- training_sessions, session_rpe generierte session_load-Spalte,
-- daily_checkins.session_load/acute_chronic_ratio), Muster-D-Autorisierung
-- der vier RPCs (nur Staff plant, nur der Spieler selbst meldet RPE, alle
-- Rollen listen team-gescoped), RLS-Isolation (Spieler sieht nur eigene RPE,
-- Staff sieht alles im Team, Cross-Team-Isolation auf beiden Tabellen),
-- Upsert-Idempotenz von rpc_submit_session_rpe, Aggregation bei mehreren
-- Einheiten am selben Tag, O-02 (Last landet auf session_date, nicht dem
-- Folgetag), RPE-Zeitfenster (wie rpc_submit_checkin), acute_chronic_ratio
-- Division-durch-Null, und dass app.cron_training_load die beiden
-- bestehenden Nachtlaeufe (Baseline-Engine, LoadDeviation) strukturell nicht
-- beruehrt. Vierte Review-Runde: ACWR-Mittelwerte team-gefiltert nach
-- Teamwechsel (9f) und Team-Mismatch ohne JWT-Claims im Cron-Kontext (9g).
-- Fuenfte Runde: der Nachtlauf schliesst den Vortag ab und belegt heute nie
-- mit einer 0 (9), Integrationstest Nachtlauf -> Baseline -> Deviation ->
-- LoadDeviation ohne session_load.below-Fehlalarm inkl. Gegenprobe (9h),
-- Neuberechnung beider Tage beim Verschieben einer Einheit (9i).
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(131);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f6000000-0000-0000-0000-000000000001','Team F6','Europe/Berlin'),
  ('f6000000-0000-0000-0000-000000000008','Team F6b (fremd)','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','Spieler1 F6','stuermer','f6100000-0000-0000-0000-000000000001',true),
  ('f6100000-0000-0000-0000-000000000002','f6000000-0000-0000-0000-000000000001','Coach F6','coach','f6100000-0000-0000-0000-000000000002',true),
  ('f6100000-0000-0000-0000-000000000003','f6000000-0000-0000-0000-000000000001','Spieler3 F6','verteidiger','f6100000-0000-0000-0000-000000000003',true),
  ('f6100000-0000-0000-0000-000000000005','f6000000-0000-0000-0000-000000000001','Spieler5 F6 (ohne Training)','torwart','f6100000-0000-0000-0000-000000000005',true),
  ('f6100000-0000-0000-0000-000000000008','f6000000-0000-0000-0000-000000000008','Coach F6b (fremd)','coach','f6100000-0000-0000-0000-000000000008',true),
  ('f6100000-0000-0000-0000-000000000009','f6000000-0000-0000-0000-000000000008','Spieler9 F6b (fremd)','stuermerin','f6100000-0000-0000-0000-000000000009',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000002','coach',  now() - interval '90 days', NULL),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000003','player', now() - interval '90 days', NULL),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000005','player', now() - interval '90 days', NULL),
  ('f6000000-0000-0000-0000-000000000008','f6100000-0000-0000-0000-000000000008','coach',  now() - interval '90 days', NULL),
  ('f6000000-0000-0000-0000-000000000008','f6100000-0000-0000-0000-000000000009','player', now() - interval '90 days', NULL);

CREATE OR REPLACE FUNCTION app._t38_jwt(p_sub text, p_role text, p_team text DEFAULT 'f6000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- -----------------------------------------------------------------------------
-- 1. Struktur
-- -----------------------------------------------------------------------------
SELECT has_type('app', 'app_session_type', 'app.app_session_type existiert');
SELECT has_table('app', 'training_sessions', 'app.training_sessions existiert');
SELECT has_table('app', 'session_rpe', 'app.session_rpe existiert');
SELECT has_column('app', 'session_rpe', 'session_load', 'session_rpe hat die generierte Spalte session_load');
SELECT has_column('app', 'daily_checkins', 'session_load', 'daily_checkins hat session_load (AP-68)');
SELECT has_column('app', 'daily_checkins', 'acute_chronic_ratio', 'daily_checkins hat acute_chronic_ratio (AP-68)');

SELECT ok(
  has_column_privilege('authenticated', 'app.daily_checkins', 'session_load', 'SELECT'),
  'authenticated darf session_load auf daily_checkins lesen'
);
SELECT ok(
  has_column_privilege('authenticated', 'app.daily_checkins', 'acute_chronic_ratio', 'SELECT'),
  'authenticated darf acute_chronic_ratio auf daily_checkins lesen'
);
SELECT has_column('app', 'daily_checkins', 'checkin_submitted_at', 'daily_checkins hat checkin_submitted_at (Security-Review Fund 1)');
SELECT ok(
  has_column_privilege('authenticated', 'app.daily_checkins', 'checkin_submitted_at', 'SELECT'),
  'authenticated darf checkin_submitted_at auf daily_checkins lesen'
);
SELECT is(
  (SELECT numeric_precision::int FROM information_schema.columns
    WHERE table_schema = 'app' AND table_name = 'daily_checkins' AND column_name = 'session_load'),
  10, 'Security-Review Fund 5: daily_checkins.session_load ist numeric(10,3) (verbreitert, Tagessumme darf nicht ueberlaufen)'
);

-- -----------------------------------------------------------------------------
-- 1b. Security-Review Fund 3 (MITTEL): NUR SELECT fuer authenticated auf
--     beiden neuen Tabellen, kein INSERT/UPDATE mehr ueber Table-Grants --
--     der Schreibweg laeuft ausschliesslich ueber die RPCs.
-- -----------------------------------------------------------------------------
SELECT ok(
  has_table_privilege('authenticated', 'app.training_sessions', 'SELECT'),
  'authenticated darf app.training_sessions lesen'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.training_sessions', 'INSERT'),
  'authenticated hat KEIN Table-Level-INSERT mehr auf app.training_sessions (Fund 3)'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.training_sessions', 'UPDATE'),
  'authenticated hat KEIN Table-Level-UPDATE mehr auf app.training_sessions (Fund 3)'
);
SELECT ok(
  has_table_privilege('authenticated', 'app.session_rpe', 'SELECT'),
  'authenticated darf app.session_rpe lesen'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.session_rpe', 'INSERT'),
  'authenticated hat KEIN Table-Level-INSERT mehr auf app.session_rpe (Fund 3)'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app._compute_daily_session_load(uuid,date)', 'EXECUTE'),
  'authenticated darf app._compute_daily_session_load nicht direkt ausfuehren (interne Funktion)'
);

-- Dritte Review-Runde, Fund 3-Rest: die drei wirkungslosen INSERT/UPDATE-
-- Policies wurden komplett entfernt statt nur wirkungslos liegengelassen.
SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'app' AND tablename = 'training_sessions' AND policyname = 'training_sessions_insert_staff'),
  'Fund 3-Rest: training_sessions_insert_staff wurde entfernt, nicht nur wirkungslos liegengelassen'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'app' AND tablename = 'training_sessions' AND policyname = 'training_sessions_update_staff'),
  'Fund 3-Rest: training_sessions_update_staff wurde entfernt, nicht nur wirkungslos liegengelassen'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'app' AND tablename = 'session_rpe' AND policyname = 'session_rpe_insert_self'),
  'Fund 3-Rest: session_rpe_insert_self wurde entfernt, nicht nur wirkungslos liegengelassen'
);

SELECT throws_ok(
  $$INSERT INTO app.training_sessions (team_id, session_date, duration_min, created_by, goal_text)
    VALUES ('f6000000-0000-0000-0000-000000000001', current_date, 60, NULL, repeat('x', 2001))$$,
  NULL, NULL,
  'Security-Review Fund 5: goal_text laenger als 2000 Zeichen wird von der CHECK-Constraint abgelehnt'
);

-- -----------------------------------------------------------------------------
-- 1c. Dritte Review-Runde, Fund 1-Rest: Backfill-Logik. Die eigentliche
--     Migration lief gegen eine leere Tabelle (frische lokale Test-DB, 0
--     Bestandszeilen) -- hier wird dieselbe UPDATE-Anweisung wortgleich
--     erneut gegen zwei simulierte "Altzeilen" ausgefuehrt (Backfill ist
--     idempotent: WHERE checkin_submitted_at IS NULL), um die Bedingung
--     selbst zu pruefen: eine Zeile mit einem echten Wellness-Feld bekommt
--     checkin_submitted_at nachgetragen, eine reine Trainingslast-Zeile
--     (nur session_load gesetzt) bleibt unangetastet.
-- -----------------------------------------------------------------------------
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at)
VALUES ('f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-000000000001', current_date - 20, 7, now() - interval '5 days');

INSERT INTO app.daily_checkins (team_id, person_id, date, session_load, submitted_at)
VALUES ('f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-000000000001', current_date - 21, 300, now() - interval '4 days');

UPDATE app.daily_checkins SET checkin_submitted_at = submitted_at
 WHERE checkin_submitted_at IS NULL
   AND (sleep_duration_min IS NOT NULL OR sleep_quality IS NOT NULL OR recovery IS NOT NULL
        OR energy IS NOT NULL OR mental_stress IS NOT NULL OR mental_mood IS NOT NULL
        OR mental_motivation IS NOT NULL OR training_readiness IS NOT NULL OR body_map IS NOT NULL);

SELECT is(
  (SELECT checkin_submitted_at FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date - 20),
  (SELECT submitted_at FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date - 20),
  'Backfill: eine Altzeile mit echtem Wellness-Feld bekommt checkin_submitted_at = submitted_at nachgetragen'
);
SELECT is(
  (SELECT checkin_submitted_at FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date - 21),
  NULL,
  'Backfill: eine reine Trainingslast-Altzeile (nur session_load) bleibt unangetastet, checkin_submitted_at weiterhin NULL'
);

-- -----------------------------------------------------------------------------
-- 2. rpc_create_training_session — nur Staff, team_id/created_by aus Helpern
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT ok(
  app.is_denial(app.rpc_create_training_session(current_date, '18:00'::time, 90::smallint, 'field'::app.app_session_type, 6::smallint, 'Testeinheit')),
  'Spieler darf keine Trainingseinheit anlegen'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date, '18:00'::time, 90::smallint, 'field'::app.app_session_type, 6::smallint, 'Haupteinheit')),
  'Coach darf eine Trainingseinheit anlegen'
);
RESET ROLE;

SELECT is(
  (SELECT team_id FROM app.training_sessions WHERE goal_text = 'Haupteinheit'),
  'f6000000-0000-0000-0000-000000000001'::uuid,
  'team_id kommt aus dem Waechter, nicht aus Parametern'
);
SELECT is(
  (SELECT created_by FROM app.training_sessions WHERE goal_text = 'Haupteinheit'),
  'f6100000-0000-0000-0000-000000000002'::uuid,
  'created_by kommt aus dem Waechter, nicht aus Parametern'
);
SELECT is(
  (SELECT session_type::text FROM app.training_sessions WHERE goal_text = 'Haupteinheit'),
  'field', 'session_type wie angegeben'
);

-- Zweite Einheit am selben Tag (Nachmittag), fuer die Aggregations-Tests unten.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date, '16:00'::time, 45::smallint, 'gym'::app.app_session_type, 4::smallint, 'Zusatzeinheit')),
  'Coach darf eine zweite Einheit am selben Tag anlegen (kein Teilgruppen-/Status-Feld, jede Einheit team-weit)'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 2b. Code-Review-Fund 2: duration_min braucht eine Obergrenze, sonst
--     numeric field overflow bei session_load = rpe * duration_min
--     (numeric(8,3), max 99999.999). 300 ist die Grenze, 301 muss abgelehnt
--     werden, 300 muss durchgehen (Grenzfall exakt an der Kante).
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok(
  $$SELECT app.rpc_create_training_session(current_date, NULL::time, 301::smallint, 'field'::app.app_session_type, NULL, 'Zu lang')$$,
  '22023', NULL,
  'duration_min = 301 wird abgelehnt (Obergrenze, verhindert numeric field overflow bei session_load)'
);
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date, NULL::time, 300::smallint, 'field'::app.app_session_type, NULL, 'Grenzfall 300')),
  'duration_min = 300 (Grenzfall, genau an der Kante) wird noch akzeptiert'
);
RESET ROLE;

SELECT throws_ok(
  $$INSERT INTO app.training_sessions (team_id, session_date, duration_min, created_by)
    VALUES ('f6000000-0000-0000-0000-000000000001', current_date, 301, 'f6100000-0000-0000-0000-000000000002')$$,
  NULL, NULL,
  'duration_min = 301 wird auch von der CHECK-Constraint auf der Tabelle selbst abgelehnt (zweite Sicherheitsebene)'
);

-- Security-Review Fund 3: dieselbe Obergrenze gilt jetzt auch direkt auf
-- app.session_rpe (bisher KEIN CHECK dort) -- getestet gegen eine bereits
-- existierende Einheit (Haupteinheit, oben angelegt). Als Superuser
-- ausgefuehrt (bewusst kein SET ROLE), damit ausschliesslich die CHECK-
-- Constraint geprueft wird, nicht das seit Fund 3 fehlende INSERT-Recht.
SELECT throws_ok(
  $$INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min)
    SELECT 'f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-000000000001', ts.id, 5, -5
      FROM app.training_sessions ts WHERE goal_text = 'Haupteinheit'$$,
  NULL, NULL,
  'session_rpe.duration_min = -5 wird von der CHECK-Constraint abgelehnt'
);
SELECT throws_ok(
  $$INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min)
    SELECT 'f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-000000000001', ts.id, 5, 301
      FROM app.training_sessions ts WHERE goal_text = 'Haupteinheit'$$,
  NULL, NULL,
  'session_rpe.duration_min = 301 wird von der CHECK-Constraint abgelehnt (Konsistenz zu training_sessions)'
);

-- -----------------------------------------------------------------------------
-- 3. rpc_update_training_session — nur Staff, nur eigenes Team
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000008', 'coach', 'f6000000-0000-0000-0000-000000000008');
SELECT ok(
  app.is_denial(app.rpc_update_training_session(
    (SELECT id FROM app.training_sessions WHERE goal_text = 'Haupteinheit'),
    current_date, '19:00'::time, 100::smallint, 'field'::app.app_session_type, 7::smallint, 'Uebernahmeversuch'
  )),
  'Coach eines fremden Teams darf eine Einheit dieses Teams nicht aendern'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_update_training_session(
    (SELECT id FROM app.training_sessions WHERE goal_text = 'Haupteinheit'),
    current_date, '18:30'::time, 100::smallint, 'field'::app.app_session_type, 7::smallint, 'Haupteinheit angepasst'
  )),
  'Coach des eigenen Teams darf die Einheit aendern'
);
RESET ROLE;

SELECT is(
  (SELECT goal_text FROM app.training_sessions WHERE duration_min = 100),
  'Haupteinheit angepasst', 'Update hat die Felder tatsaechlich geaendert'
);

-- -----------------------------------------------------------------------------
-- 4. rpc_list_training_sessions — alle Rollen, team-gescoped
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT is(
  (SELECT count(*)::int FROM jsonb_array_elements(app.rpc_list_training_sessions(current_date, current_date))),
  3, 'Spieler sieht alle drei Einheiten des eigenen Teams am heutigen Tag (Haupt-, Zusatz- und Grenzfall-300-Einheit)'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000009', 'player', 'f6000000-0000-0000-0000-000000000008');
SELECT is(
  (SELECT count(*)::int FROM jsonb_array_elements(app.rpc_list_training_sessions(current_date, current_date))),
  0, 'Fremdes Team sieht keine der Einheiten (Cross-Team-Isolation)'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5. rpc_submit_session_rpe — nur der Spieler selbst, Aggregation ueber
--    mehrere Einheiten am selben Tag (O-02: Last auf session_date)
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  app.is_denial(app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE duration_min = 100), 7::smallint)),
  'Coach darf kein RPE fuer sich selbst abgeben (nur Rolle player)'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE duration_min = 100), 7::smallint)$$,
  'Spieler1 gibt RPE fuer die Haupteinheit ab (7 * 100 = 700)'
);
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE duration_min = 45), 5::smallint)$$,
  'Spieler1 gibt RPE fuer die Zusatzeinheit ab (5 * 45 = 225)'
);
RESET ROLE;

SELECT is(
  (SELECT session_load FROM app.session_rpe
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001'
      AND session_id = (SELECT id FROM app.training_sessions WHERE duration_min = 100)),
  700.000, 'generierte session_load = rpe * duration_min (Haupteinheit)'
);

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date),
  925.000, '_compute_daily_session_load summiert beide Einheiten desselben Tages (700 + 225)'
);

-- O-02: Session Load zaehlt auf session_date, nicht auf den Folgetag.
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM app.daily_checkins
     WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date + 1
       AND session_load IS NOT NULL AND session_load <> 0
  ),
  'O-02: keine Last auf dem Folgetag der Einheiten'
);

-- -----------------------------------------------------------------------------
-- 6. Upsert-Idempotenz: ein zweiter Aufruf fuer dieselbe Einheit ersetzt,
--    keine zweite Zeile.
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE duration_min = 100), 3::smallint)$$,
  'Spieler1 korrigiert das RPE der Haupteinheit auf 3'
);
RESET ROLE;

SELECT is(
  (SELECT count(*)::int FROM app.session_rpe
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001'
      AND session_id = (SELECT id FROM app.training_sessions WHERE duration_min = 100)),
  1, 'Upsert: weiterhin genau eine Zeile je (person_id, session_id)'
);
SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date),
  525.000, 'Tagessumme nach Korrektur neu berechnet (3*100 + 5*45 = 525)'
);

-- -----------------------------------------------------------------------------
-- 7. Zeitfenster wie rpc_submit_checkin (heute oder bis zu 2 Tage zurueck,
--    bezogen auf training_sessions.session_date)
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date - 2, NULL::time, 60::smallint, 'recovery'::app.app_session_type, 3::smallint, 'Grenzfall innerhalb')),
  'Fixture: Einheit vor 2 Tagen angelegt (Grenzfall innerhalb des Fensters)'
);
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date - 3, NULL::time, 60::smallint, 'recovery'::app.app_session_type, 3::smallint, 'Grenzfall ausserhalb')),
  'Fixture: Einheit vor 3 Tagen angelegt (ausserhalb des Fensters)'
);
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date + 1, NULL::time, 60::smallint, 'tactical'::app.app_session_type, 3::smallint, 'Zukuenftige Einheit')),
  'Fixture: Einheit fuer morgen angelegt (ausserhalb des Fensters)'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE goal_text = 'Grenzfall innerhalb'), 5::smallint)$$,
  'RPE fuer eine Einheit vor genau 2 Tagen ist noch zulaessig'
);
SELECT ok(
  app.is_denial(app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE goal_text = 'Grenzfall ausserhalb'), 5::smallint)),
  'RPE fuer eine Einheit vor 3 Tagen ist abgelehnt (ausserhalb des Fensters)'
);
SELECT ok(
  app.is_denial(app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE goal_text = 'Zukuenftige Einheit'), 5::smallint)),
  'RPE fuer eine Einheit von morgen ist abgelehnt (ausserhalb des Fensters)'
);
SELECT throws_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE goal_text = 'Grenzfall innerhalb'), 11::smallint)$$,
  '22023', NULL,
  'RPE ausserhalb 1-10 wird als Eingabefehler abgelehnt (nicht als Berechtigungsfrage)'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 8. RLS-Isolation: Spieler sieht nur eigene RPE, Staff sieht alles im Team,
--    Cross-Team-Isolation auf training_sessions und session_rpe.
-- -----------------------------------------------------------------------------
-- Spieler3 gibt ebenfalls RPE fuer die Haupteinheit ab, damit die Isolation
-- zwischen zwei echten Spieler-Zeilen geprueft werden kann (nicht nur
-- Spieler-vs-Staff).
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000003', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE duration_min = 100), 4::smallint)$$,
  'Spieler3 gibt ebenfalls RPE fuer dieselbe Einheit ab (Fixture fuer Isolationstest)'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT is(
  (SELECT count(DISTINCT person_id)::int FROM app.session_rpe),
  1, 'Spieler1 sieht per RLS direkt auf der Tabelle nur die eigene RPE-Zeile'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (SELECT count(DISTINCT person_id)::int FROM app.session_rpe),
  2, 'Staff sieht per RLS alle RPE-Zeilen im eigenen Team (Spieler1 und Spieler3)'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000009', 'player', 'f6000000-0000-0000-0000-000000000008');
SELECT is(
  (SELECT count(*)::int FROM app.session_rpe),
  0, 'Cross-Team-Isolation: fremdes Team sieht per RLS 0 Zeilen aus app.session_rpe'
);
SELECT is(
  (SELECT count(*)::int FROM app.training_sessions),
  0, 'Cross-Team-Isolation: fremdes Team sieht per RLS 0 Zeilen aus app.training_sessions'
);
RESET ROLE;

-- Direkter INSERT als Spieler wird abgelehnt (Security-Review Fund 3:
-- authenticated hat seit dieser Runde gar kein Table-Level-INSERT mehr auf
-- app.training_sessions -- die Rechtepruefung greift schon vor jeder
-- RLS-Auswertung). Der eigentliche Schreibweg ist ohnehin die SECURITY
-- DEFINER Tuer.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT throws_ok(
  $$INSERT INTO app.training_sessions (team_id, session_date, duration_min, created_by)
    VALUES ('f6000000-0000-0000-0000-000000000001', current_date, 60, 'f6100000-0000-0000-0000-000000000001')$$,
  NULL, NULL,
  'Direkter INSERT eines Spielers auf app.training_sessions wird abgelehnt (kein GRANT mehr, Fund 3)'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 8b. Security-Review Fund 3 (Reviewer-Vorschlag): Cross-Team-Versuch bei
--     rpc_submit_session_rpe mit einer session_id, die zu einem ANDEREN Team
--     gehoert -- das darf niemals ueber den Team-Lookup der eigenen Person
--     hinaus etwas anderes Teams treffen.
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000009', 'player', 'f6000000-0000-0000-0000-000000000008');
SELECT ok(
  app.is_denial(app.rpc_submit_session_rpe(
    (SELECT id FROM app.training_sessions WHERE duration_min = 100),
    5::smallint
  )),
  'Spieler eines fremden Teams (F6b) darf kein RPE fuer eine session_id aus Team F6 abgeben'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 9. app.cron_training_load: schliesst den VORTAG ab (fuenfte Runde), nie
--    heute. acute_chronic_ratio: Division durch Null -> NULL, kein Fehler.
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.cron_training_load()$$,
  'app.cron_training_load laeuft ohne Fehler (auch fuer Personen ganz ohne Training)'
);

SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1),
  NULL,
  'Spieler5 ohne jede Trainingslast: chronic = 0 -> acute_chronic_ratio (Vortag) ist NULL, kein Fehler'
);

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1),
  0.000,
  'Spieler5 ohne Training: session_load des abgeschlossenen Vortags ist 0, nicht NULL (Ruhetag zaehlt als 0)'
);

-- Fuenfte Runde (HOCH): der Nachtlauf darf den HEUTIGEN Tag nicht vorzeitig
-- mit einer 0 belegen -- sonst bewertet die Baseline-Engine um 03:00 eine
-- kuenstliche 0 und erzeugt taeglich einen session_load.below-Fehlalarm.
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM app.daily_checkins
     WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date
  ),
  'Fuenfte Runde: Spieler5 (kein Training, keine RPE) hat nach dem Nachtlauf KEINE Zeile fuer heute'
);
SELECT is(
  (SELECT count(*)::int FROM app.daily_checkins
    WHERE date = current_date AND session_load = 0),
  0,
  'Fuenfte Runde: nach dem Nachtlauf existiert fuer heute keine einzige Zeile mit session_load = 0'
);
SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date),
  525.000,
  'Fuenfte Runde: Spieler1s heutige echte Last (aus RPE, 525) bleibt vom Nachtlauf unberuehrt'
);
SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date),
  NULL,
  'Fuenfte Runde: der Nachtlauf schreibt keine ACWR auf den heutigen, noch offenen Tag'
);

-- Security-Review Fund 1 (Teil 2): die Cron-Schleife ist jetzt auf Rolle
-- player beschraenkt -- Coach F6 (Staff) bekommt gar keine Trainingslast-
-- Zeile vom Nachtlauf, weder session_load noch acute_chronic_ratio.
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM app.daily_checkins
     WHERE person_id = 'f6100000-0000-0000-0000-000000000002' AND date >= current_date - 1
  ),
  'Security-Review Fund 1: Coach (Staff) bekommt vom Nachtlauf keine daily_checkins-Zeile (Schleife nur noch Rolle player)'
);

-- -----------------------------------------------------------------------------
-- 9b. Security-Review Fund 2 (MITTEL, Silo-Bruch bei Teamwechsel): eine
--     bestehende daily_checkins-Zeile eines Teams darf nach einem
--     Teamwechsel der Person NICHT vom neuen Team ueberschrieben werden --
--     und der Aufruf darf trotzdem nicht mit einer Exception abbrechen
--     (sonst wuerde ein einzelner Teamwechsel den gesamten Nachtlauf fuer
--     ALLE anderen Personen mitreissen).
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT team_id FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1),
  'f6000000-0000-0000-0000-000000000001'::uuid,
  'Vorbedingung: Spieler5s Vortagszeile (vom Nachtlauf) gehoert noch Team F6'
);

UPDATE app.persons SET team_id = 'f6000000-0000-0000-0000-000000000008'
 WHERE id = 'f6100000-0000-0000-0000-000000000005';
-- Auch role_assignments muss auf das neue Team zeigen, sonst bestaetigt
-- app.auth_team_id() die Claims gar nicht (kein confirmed team -> log_denial
-- selbst wuerde beim naechsten Schritt sofort mit "kein Team" aussteigen,
-- siehe app.log_denial-Kopfkommentar in backend/09_rpcs.sql) -- exakt das
-- Modell eines abgeschlossenen Teamwechsels wie in Abschnitt 9e.
UPDATE app.role_assignments SET team_id = 'f6000000-0000-0000-0000-000000000008'
 WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND role = 'player' AND valid_to IS NULL;

-- Dritte Review-Runde, Fund 2-Rest: der stille RETURN NULL protokolliert
-- jetzt per app.log_denial -- mit gueltigen, bestaetigten JWT-Claims im
-- Kontext (hier ueber _t38_jwt gesetzt, kein SET ROLE noetig, log_denial
-- liest nur die GUC) entsteht dafuer eine Zeile in app.access_denials.
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000005', 'player', 'f6000000-0000-0000-0000-000000000008');
SELECT is(
  (SELECT count(*)::int FROM app.access_denials
    WHERE resource = 'daily_checkins.team' AND actor_id = 'f6100000-0000-0000-0000-000000000005'),
  0, 'Vorbedingung: noch keine access_denials-Zeile fuer diesen Grund'
);

SELECT lives_ok(
  $$SELECT app._compute_daily_session_load('f6100000-0000-0000-0000-000000000005', current_date - 1)$$,
  'Aufruf nach simuliertem Teamwechsel laeuft ohne Exception (kein Abbruch des Cron-Laufs fuer andere Personen)'
);

SELECT is(
  (SELECT count(*)::int FROM app.access_denials
    WHERE resource = 'daily_checkins.team' AND actor_id = 'f6100000-0000-0000-0000-000000000005'),
  1, 'Fund 2-Rest: der Team-Mismatch hinterlaesst jetzt eine Spur in app.access_denials (statt still zu verschwinden)'
);

SELECT is(
  (SELECT team_id FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1),
  'f6000000-0000-0000-0000-000000000001'::uuid,
  'Fund 2: die bestehende Zeile bleibt beim ALTEN Team F6 -- kein Ueberschreiben mit dem neuen Team F6b'
);
SELECT is(
  (SELECT count(*)::int FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1),
  1, 'Fund 2: es entsteht keine zweite Zeile fuer das neue Team (unique ist auf person_id+date, nicht team_id)'
);

UPDATE app.role_assignments SET team_id = 'f6000000-0000-0000-0000-000000000001'
 WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND role = 'player' AND valid_to IS NULL;
UPDATE app.persons SET team_id = 'f6000000-0000-0000-0000-000000000001'
 WHERE id = 'f6100000-0000-0000-0000-000000000005';

-- -----------------------------------------------------------------------------
-- 9c. Security-Review Fund 1 (HOCH): hasCheckIn bleibt false nach dem
--     Trainingslast-Nachtlauf, solange keine echte rpc_submit_checkin
--     stattgefunden hat. Positivkontrolle: nach einem echten Check-in wird
--     hasCheckIn true.
-- -----------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (SELECT (m -> 'hasCheckIn')::boolean FROM jsonb_array_elements(app.rpc_morning_ops() -> 'members') m
    WHERE m #>> '{player,id}' = 'f6100000-0000-0000-0000-000000000001'),
  false,
  'Fund 1: Spieler1 hat Trainingslast (aus RPE) aber KEINEN echten Check-in -> hasCheckIn bleibt false'
);
SELECT is(
  (SELECT (m -> 'hasCheckIn')::boolean FROM jsonb_array_elements(app.rpc_morning_ops() -> 'members') m
    WHERE m #>> '{player,id}' = 'f6100000-0000-0000-0000-000000000005'),
  false,
  'Fund 1: Spieler5 hat nur eine vom Nachtlauf angelegte Lastzeile (Vortag, session_load=0), heute gar keine -> hasCheckIn bleibt false'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000003', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_checkin(current_date, 480, 8, 7, 6, 3, 8, 7, 8, NULL)$$,
  'Positivkontrolle: Spieler3 gibt einen echten Wellness-Check-in ab'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (SELECT (m -> 'hasCheckIn')::boolean FROM jsonb_array_elements(app.rpc_morning_ops() -> 'members') m
    WHERE m #>> '{player,id}' = 'f6100000-0000-0000-0000-000000000003'),
  true,
  'Positivkontrolle: nach echtem rpc_submit_checkin ist hasCheckIn fuer Spieler3 true'
);
RESET ROLE;

SELECT is(
  (SELECT checkin_submitted_at IS NOT NULL FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND date = current_date),
  true,
  'rpc_submit_checkin setzt checkin_submitted_at'
);
SELECT is(
  (SELECT checkin_submitted_at FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = current_date),
  NULL,
  'app._compute_daily_session_load setzt checkin_submitted_at niemals (Spieler1 hat trotz mehrfacher RPE-Abgabe weiterhin NULL)'
);

-- -----------------------------------------------------------------------------
-- 9d. Dritte Review-Runde, Fund 1-Rest: eine reine Trainingslast-Zeile darf
--     auch in der Medizin-Sicht (rpc_check_ins_medical) und in der eigenen
--     Body-Map-Historie (rpc_my_body_map_history) NICHT als Check-in
--     auftauchen. Positivkontrolle mit Spieler3, die/der in Abschnitt 9c
--     bereits einen echten Check-in abgegeben hat.
-- -----------------------------------------------------------------------------
-- Fuenfte Runde: die reine Lastzeile vom Nachtlauf liegt jetzt auf dem
-- Vortag, deshalb laufen beide Abfragen ueber Vortag bis heute (2 Tage).
SELECT ok(
  EXISTS (SELECT 1 FROM app.daily_checkins
           WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date - 1
             AND checkin_submitted_at IS NULL),
  'Vorbedingung: Spieler5 hat eine reine Trainingslast-Zeile (Vortag, ohne checkin_submitted_at) im Abfragefenster'
);

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000005', 'player');
SELECT is(
  (SELECT jsonb_array_length(app.rpc_check_ins_medical('f6100000-0000-0000-0000-000000000005', current_date - 1, current_date) -> 'checkins')),
  0,
  'Fund 1-Rest: reine Trainingslast-Zeile (Spieler5) erscheint NICHT in rpc_check_ins_medical'
);
SELECT is(
  (SELECT jsonb_array_length(app.rpc_my_body_map_history(2) -> 'checkins')),
  0,
  'Fund 1-Rest: dieselbe Zeile erscheint NICHT im checkins-Array von rpc_my_body_map_history'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000003', 'player');
SELECT is(
  (SELECT jsonb_array_length(app.rpc_check_ins_medical('f6100000-0000-0000-0000-000000000003', current_date - 1, current_date) -> 'checkins')),
  1,
  'Positivkontrolle: Spieler3s echter Check-in erscheint weiterhin in rpc_check_ins_medical (Vortags-Lastzeile nicht)'
);
SELECT is(
  (SELECT jsonb_array_length(app.rpc_my_body_map_history(2) -> 'checkins')),
  1,
  'Positivkontrolle: Spieler3s echter Check-in erscheint weiterhin im checkins-Array von rpc_my_body_map_history (Vortags-Lastzeile nicht)'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 9e. Dritte Review-Runde, Fund 2-Rest: die ACWR-Schleife in app.cron_
--     training_load() hatte keinen Teamfilter im finalen UPDATE. Simulierter
--     abgeschlossener Teamwechsel (persons.team_id UND role_assignments.
--     team_id zeigen schon auf das neue Team F6b), aber die as_of-Zeile
--     (seit der fuenften Runde der Vortag) ist noch vom alten Team F6 -- das
--     UPDATE darf diese Zeile NICHT treffen.
-- -----------------------------------------------------------------------------
UPDATE app.daily_checkins SET acute_chronic_ratio = 9.999
 WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND date = current_date - 1;

UPDATE app.role_assignments SET team_id = 'f6000000-0000-0000-0000-000000000008'
 WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND role = 'player' AND valid_to IS NULL;
UPDATE app.persons SET team_id = 'f6000000-0000-0000-0000-000000000008'
 WHERE id = 'f6100000-0000-0000-0000-000000000003';

SELECT lives_ok(
  $$SELECT app.cron_training_load()$$,
  'app.cron_training_load laeuft nach einem abgeschlossenen Teamwechsel weiterhin ohne Exception'
);

SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND date = current_date - 1),
  9.999,
  'Fund 2-Rest: das ACWR-UPDATE trifft die Vortagszeile des ALTEN Teams nach einem Teamwechsel NICHT (Sentinel-Wert unveraendert)'
);

-- Aufraeumen: Spieler3 zurueck ins Team F6, fuer den Rest der Suite.
UPDATE app.role_assignments SET team_id = 'f6000000-0000-0000-0000-000000000001'
 WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND role = 'player' AND valid_to IS NULL;
UPDATE app.persons SET team_id = 'f6000000-0000-0000-0000-000000000001'
 WHERE id = 'f6100000-0000-0000-0000-000000000003';

-- -----------------------------------------------------------------------------
-- 9f. Vierte Review-Runde, Fund 1-Rest: die beiden avg()-Abfragen (acute 7
--     Tage, chronic 28 Tage) in app.cron_training_load() muessen auf das
--     AKTUELLE Team der Person filtern. Spieler7 hat den Teamwechsel F6 ->
--     F6b bereits abgeschlossen (persons.team_id und role_assignments zeigen
--     auf F6b), aber Zeilen des ALTEN Teams F6 aus der Zeit vor dem Wechsel
--     liegen noch im 7-/28-Tage-Fenster (Sentinel-Last 1000). Seit der
--     fuenften Runde ist as_of der Vortag (Tag -1), die Fixture liegt
--     deshalb einen Tag weiter zurueck als in Runde 4:
--       neues Team F6b: Tag -13 = 400, Tag -2 = 100, Tag -1 = 0 (Nachtlauf)
--       altes Team F6:  Tag -11 = 1000, Tag -4 = 1000 (Sentinel)
--     mit Teamfilter:  acute = (100+0)/2 = 50, chronic = (400+100+0)/3
--                      = 166.667 -> ratio 0.300
--     ohne Teamfilter: acute = (1000+100+0)/3 = 366.667, chronic =
--                      (1000+1000+400+100+0)/5 = 500 -> ratio 0.733
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000007','f6000000-0000-0000-0000-000000000008','Spieler7 (gewechselt F6 -> F6b)','mittelfeld','f6100000-0000-0000-0000-000000000007',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000008','f6100000-0000-0000-0000-000000000007','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, session_load) VALUES
  ('f6000000-0000-0000-0000-000000000008','f6100000-0000-0000-0000-000000000007', current_date - 13,  400),
  ('f6000000-0000-0000-0000-000000000008','f6100000-0000-0000-0000-000000000007', current_date - 2,   100),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000007', current_date - 11, 1000),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000007', current_date - 4,  1000);

SELECT lives_ok(
  $$SELECT app.cron_training_load()$$,
  'Fund 1-Rest: app.cron_training_load laeuft mit Alt-Team-Zeilen im Fenster ohne Exception'
);

SELECT is(
  (SELECT team_id FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000007' AND date = current_date - 1),
  'f6000000-0000-0000-0000-000000000008'::uuid,
  'Vorbedingung: Spieler7s Vortagszeile (vom Nachtlauf angelegt) gehoert dem neuen Team F6b'
);

SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000007' AND date = current_date - 1),
  0.300,
  'Fund 1-Rest: acute/chronic-Mittel beziehen nur Tage des aktuellen Teams ein (0.300, ohne Teamfilter waere es 0.733)'
);

-- -----------------------------------------------------------------------------
-- 9g. Vierte Review-Runde, Fund 2-Rest: Team-Mismatch im echten Cron-Kontext
--     (KEINE JWT-Claims, wie bei pg_cron/service_role). app.log_denial ist
--     dort garantiert ein No-Op -- die Funktion muss trotzdem NULL liefern,
--     darf nicht abbrechen und meldet den Mismatch per RAISE WARNING
--     (non-fatal, von pgTAP nicht abfangbar, daher strukturell geprueft).
--     Fixture: Spieler7 (inzwischen Team F6b) hat fuer die F6-Einheit
--     "Grenzfall ausserhalb" (vor 3 Tagen; Tag -2 ist seit der fuenften
--     Runde durch die 9f-Fixture belegt) noch einen RPE-Eintrag des ALTEN
--     Teams F6 und eine daily_checkins-Zeile des alten Teams (Sentinel 777).
--     RPE direkt als Superuser eingefuegt, das Zeitfenster der Tuer spielt
--     hier keine Rolle.
-- -----------------------------------------------------------------------------
INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min)
SELECT 'f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-000000000007', ts.id, 5, 60
  FROM app.training_sessions ts WHERE ts.goal_text = 'Grenzfall ausserhalb';
INSERT INTO app.daily_checkins (team_id, person_id, date, session_load) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000007', current_date - 3, 777);

-- JWT-Claims aus frueheren Abschnitten entfernen (set_config(..., true) gilt
-- transaktionsweit) -- simuliert den Cron-Kontext ohne Request.
SELECT set_config('request.jwt.claims', '', true);

SELECT ok(
  app.auth_team_id() IS NULL AND app.auth_person_id() IS NULL,
  'Vorbedingung: kein JWT-Kontext (auth_team_id/auth_person_id sind NULL, wie im Cron-Lauf)'
);

SELECT is(
  app._compute_daily_session_load('f6100000-0000-0000-0000-000000000007', current_date - 3),
  NULL::numeric,
  'Fund 2-Rest: Team-Mismatch ohne JWT-Claims liefert NULL'
);

SELECT lives_ok(
  $$SELECT app._compute_daily_session_load('f6100000-0000-0000-0000-000000000007', current_date - 3)$$,
  'Fund 2-Rest: Team-Mismatch ohne JWT-Claims bricht nicht ab (RAISE WARNING ist non-fatal)'
);

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000007' AND date = current_date - 3),
  777.000,
  'Fund 2-Rest: die Zeile des alten Teams bleibt unveraendert (Sentinel 777, kein Ueberschreiben)'
);

SELECT is(
  (SELECT count(*)::int FROM app.access_denials
    WHERE actor_id = 'f6100000-0000-0000-0000-000000000007'),
  0,
  'Fund 2-Rest: ohne JWT-Claims schreibt log_denial nichts (No-Op) -- deshalb braucht es die WARNING'
);

SELECT ok(
  (SELECT prosrc FROM pg_proc WHERE oid = 'app._compute_daily_session_load(uuid,date)'::regprocedure)
    ~ 'RAISE WARNING ''app\._compute_daily_session_load: Team-Mismatch',
  'Fund 2-Rest: _compute_daily_session_load meldet den Team-Mismatch per RAISE WARNING (claims-unabhaengige Spur im Postgres-Log)'
);

-- -----------------------------------------------------------------------------
-- 9h. Fuenfte Runde (HOCH), Integrationstest ueber die ganze Nachtkette:
--     02:30 app.cron_training_load -> 03:00 app._compute_baseline + app.
--     rpc_compute_deviations -> 03:30 app.rpc_compute_load_deviations.
--     Spieler10 trainiert regelmaessig (28 Tage je 480), die Einheit von
--     gestern ist per RPE gemeldet, die Einheit von heute hat noch nicht
--     stattgefunden (keine RPE). Erwartung: KEIN session_load.below-
--     Fehlalarm fuer heute. Gegenprobe am Ende: wird fuer heute eine 0
--     angelegt (das alte Verhalten), entsteht genau dieser Fehlalarm -- der
--     Test ist also scharf, nicht zufaellig gruen.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-00000000000a','f6000000-0000-0000-0000-000000000001','Spieler10 F6 (trainiert regelmaessig)','mittelfeld','f6100000-0000-0000-0000-00000000000a',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-00000000000a','player', now() - interval '90 days', NULL);

-- Historie Tag -28 bis Tag -2: jeden Tag 480 (RPE 6 x 80 min).
INSERT INTO app.daily_checkins (team_id, person_id, date, session_load)
SELECT 'f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-00000000000a', current_date - g, 480
  FROM generate_series(2, 28) g;

INSERT INTO app.training_sessions (team_id, session_date, duration_min, session_type, goal_text) VALUES
  ('f6000000-0000-0000-0000-000000000001', current_date - 1, 80, 'field', '9h gestern'),
  ('f6000000-0000-0000-0000-000000000001', current_date,     80, 'field', '9h heute, noch nicht trainiert');
INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min)
SELECT 'f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-00000000000a', ts.id, 6, 80
  FROM app.training_sessions ts WHERE ts.goal_text = '9h gestern';

SELECT lives_ok(
  $$SELECT app.cron_training_load()$$,
  '9h: Nachtlauf 02:30 laeuft'
);
SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000a' AND date = current_date - 1),
  480.000,
  '9h: der abgeschlossene Vortag bekommt die echte Last aus der RPE (6 x 80 = 480)'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM app.daily_checkins
               WHERE person_id = 'f6100000-0000-0000-0000-00000000000a' AND date = current_date),
  '9h: fuer heute (Training steht noch aus) legt der Nachtlauf keine Zeile an'
);
SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000a' AND date = current_date - 1),
  1.000,
  '9h: ACWR bei konstanter Last ist exakt 1.000 (mit einer kuenstlichen 0 fuer heute im Fenster waeren es 0.889)'
);

SELECT lives_ok(
  $$SELECT app._compute_baseline('f6000000-0000-0000-0000-000000000001',
                                 'f6100000-0000-0000-0000-00000000000a',
                                 'session_load', current_date)$$,
  '9h: Baseline-Berechnung 03:00 fuer session_load laeuft'
);
SELECT is(
  (SELECT status::text || '/' || median::text FROM app.baselines
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000a'
      AND metric = 'session_load' AND as_of = current_date),
  'ok/480.000',
  '9h: Baseline 03:00 fuer session_load steht (status ok, Median 480 aus dem Fenster [heute-28, heute-1])'
);
SELECT is(
  (SELECT count(*)::int FROM app.rpc_compute_deviations('f6100000-0000-0000-0000-00000000000a', current_date)
    WHERE metric = 'session_load'),
  0,
  '9h: rpc_compute_deviations erzeugt fuer heute KEINE session_load-Abweichung (kein Wert fuer heute -> uebersprungen)'
);
SELECT lives_ok(
  $$SELECT app.rpc_compute_load_deviations(current_date)$$,
  '9h: LoadDeviation-Nachtlauf 03:30 laeuft'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM app.load_deviations
               WHERE person_id = 'f6100000-0000-0000-0000-00000000000a' AND metric = 'session_load'),
  '9h: KEIN session_load.below-Fehlalarm fuer eine regelmaessig trainierende Person'
);

-- Gegenprobe: das alte Verhalten (0 fuer heute vor dem Training) nachstellen.
INSERT INTO app.daily_checkins (team_id, person_id, date, session_load)
VALUES ('f6000000-0000-0000-0000-000000000001', 'f6100000-0000-0000-0000-00000000000a', current_date, 0);
SELECT ok(
  (SELECT z <= -1 FROM app.rpc_compute_deviations('f6100000-0000-0000-0000-00000000000a', current_date)
    WHERE metric = 'session_load'),
  '9h Gegenprobe: mit einer kuenstlichen 0 fuer heute schlaegt die Baseline-Engine an (z <= -1)'
);
SELECT lives_ok(
  $$SELECT app.rpc_compute_load_deviations(current_date)$$,
  '9h Gegenprobe: LoadDeviation-Nachtlauf laeuft erneut'
);
SELECT is(
  (SELECT count(*)::int FROM app.load_deviations
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000a' AND metric = 'session_load'
      AND date = current_date AND statement_key = 'session_load.below'),
  1,
  '9h Gegenprobe: ... und daraus entsteht genau der session_load.below-Fehlalarm, den die fuenfte Runde behebt'
);

-- -----------------------------------------------------------------------------
-- 9i. Fuenfte Runde (MITTEL): rpc_update_training_session berechnet
--     session_load fuer alten und neuen Tag neu, wenn sich session_date einer
--     Einheit mit bereits abgegebener RPE aendert. Ein offener Tag (heute)
--     bekommt dabei nie eine 0, sondern NULL.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-00000000000b','f6000000-0000-0000-0000-000000000001','Spieler11 F6 (Verschiebe-Test)','abwehr','f6100000-0000-0000-0000-00000000000b',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-00000000000b','player', now() - interval '90 days', NULL);

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date - 1, NULL::time, 50::smallint, 'field'::app.app_session_type, NULL, '9i Verschiebe-Einheit')),
  '9i Fixture: Coach legt eine Einheit fuer gestern an'
);
RESET ROLE;

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-00000000000b', 'player');
SELECT lives_ok(
  $$SELECT app.rpc_submit_session_rpe((SELECT id FROM app.training_sessions WHERE goal_text = '9i Verschiebe-Einheit'), 6::smallint)$$,
  '9i Fixture: Spieler11 meldet RPE 6 (6 x 50 = 300)'
);
RESET ROLE;

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date - 1),
  300.000,
  '9i Vorbedingung: Last 300 liegt auf gestern'
);

-- Verschieben gestern -> vorgestern.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_update_training_session(
    (SELECT id FROM app.training_sessions WHERE goal_text = '9i Verschiebe-Einheit'),
    current_date - 2, NULL::time, 50::smallint, 'field'::app.app_session_type, NULL, '9i Verschiebe-Einheit')),
  '9i: Coach verschiebt die Einheit auf vorgestern'
);
RESET ROLE;

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date - 1),
  0.000,
  '9i: alter Tag (gestern, abgeschlossen) wird neu berechnet -> 0, keine Doppelzaehlung'
);
SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date - 2),
  300.000,
  '9i: neuer Tag (vorgestern) traegt jetzt die Last 300'
);

-- Verschieben vorgestern -> heute.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_update_training_session(
    (SELECT id FROM app.training_sessions WHERE goal_text = '9i Verschiebe-Einheit'),
    current_date, NULL::time, 50::smallint, 'field'::app.app_session_type, NULL, '9i Verschiebe-Einheit')),
  '9i: Coach verschiebt die Einheit auf heute'
);
RESET ROLE;

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date - 2),
  0.000,
  '9i: vorgestern ist nach dem Wegverschieben 0'
);
SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date),
  300.000,
  '9i: heute traegt die echte Last 300 (echter Wert, keine kuenstliche 0)'
);

-- Verschieben heute -> gestern: der offene Tag heute darf KEINE 0 bekommen.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_update_training_session(
    (SELECT id FROM app.training_sessions WHERE goal_text = '9i Verschiebe-Einheit'),
    current_date - 1, NULL::time, 50::smallint, 'field'::app.app_session_type, NULL, '9i Verschiebe-Einheit')),
  '9i: Coach verschiebt die Einheit zurueck auf gestern'
);
RESET ROLE;

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date - 1),
  300.000,
  '9i: gestern traegt wieder die Last 300'
);
SELECT ok(
  (SELECT session_load IS NULL FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-00000000000b' AND date = current_date),
  '9i: der offene Tag heute wird auf NULL zurueckgesetzt, NICHT auf 0 (sonst Fehlalarm um 03:00)'
);

-- -----------------------------------------------------------------------------
-- 10. app.cron_training_load kollidiert nicht mit den bestehenden Jobs
--     (Baseline-Engine 03:00, LoadDeviation 03:30) und ist service_role-only,
--     genau wie app.cron_baseline_engine/app.cron_loaddeviation.
-- -----------------------------------------------------------------------------
SELECT has_function('app', 'cron_training_load', 'app.cron_training_load existiert');
SELECT ok(
  NOT has_function_privilege('authenticated', 'app.cron_training_load()', 'EXECUTE'),
  'authenticated darf app.cron_training_load nicht ausfuehren'
);
SELECT ok(
  has_function_privilege('service_role', 'app.cron_training_load()', 'EXECUTE'),
  'service_role darf app.cron_training_load ausfuehren (Nachtlauf 02:30)'
);
SELECT ok(
  (SELECT prosecdef FROM pg_proc WHERE oid = 'app.cron_training_load()'::regprocedure),
  'app.cron_training_load ist SECURITY DEFINER (Muster D)'
);

-- -----------------------------------------------------------------------------
-- 11. Code-Review-Fund 1: created_by ist nullable (passt zu ON DELETE SET
--     NULL). Loeschen der anlegenden Person darf die Einheit nicht
--     zerstoeren, sondern muss created_by sauber auf NULL setzen.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000006','f6000000-0000-0000-0000-000000000001','Coach6 F6 (wird geloescht)','coach','f6100000-0000-0000-0000-000000000006',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000006','coach', now() - interval '90 days', NULL);

SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000006', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_create_training_session(current_date, NULL::time, 60::smallint, 'field'::app.app_session_type, NULL, 'Einheit von Coach6')),
  'Fixture: Coach6 legt eine Einheit an (created_by = Coach6)'
);
RESET ROLE;

SELECT is(
  (SELECT created_by FROM app.training_sessions WHERE goal_text = 'Einheit von Coach6'),
  'f6100000-0000-0000-0000-000000000006'::uuid,
  'Vorbedingung: created_by zeigt auf Coach6, bevor die Person geloescht wird'
);

SELECT lives_ok(
  $$DELETE FROM app.persons WHERE id = 'f6100000-0000-0000-0000-000000000006'$$,
  'Coach6 kann geloescht werden, ohne an training_sessions.created_by zu scheitern (created_by ist nullable)'
);

SELECT is(
  (SELECT created_by FROM app.training_sessions WHERE goal_text = 'Einheit von Coach6'),
  NULL,
  'ON DELETE SET NULL greift: created_by ist nach der Personen-Loeschung NULL, die Einheit selbst bleibt als Historie erhalten'
);
SELECT ok(
  EXISTS (SELECT 1 FROM app.training_sessions WHERE goal_text = 'Einheit von Coach6'),
  'die Trainingseinheit selbst wurde durch die Personen-Loeschung nicht mitgeloescht'
);

SELECT * FROM finish();
ROLLBACK;
