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
-- beruehrt.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(56);

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

-- Direkter INSERT als Spieler wird von der RLS-Policy abgelehnt (nur Staff
-- darf ueber die WITH-CHECK-Klausel schreiben) -- der eigentliche Schreibweg
-- ist ohnehin die SECURITY DEFINER Tuer, dies ist die zweite Sicherheitsebene.
SET ROLE authenticated;
SELECT app._t38_jwt('f6100000-0000-0000-0000-000000000001', 'player');
SELECT throws_ok(
  $$INSERT INTO app.training_sessions (team_id, session_date, duration_min, created_by)
    VALUES ('f6000000-0000-0000-0000-000000000001', current_date, 60, 'f6100000-0000-0000-0000-000000000001')$$,
  NULL, NULL,
  'Direkter INSERT eines Spielers auf app.training_sessions wird von RLS abgelehnt'
);
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 9. acute_chronic_ratio: Division durch Null -> NULL, kein Fehler
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.cron_training_load()$$,
  'app.cron_training_load laeuft ohne Fehler (auch fuer Personen ganz ohne Training)'
);

SELECT is(
  (SELECT acute_chronic_ratio FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date),
  NULL,
  'Spieler5 ohne jede Trainingslast: chronic = 0 -> acute_chronic_ratio ist NULL, kein Fehler'
);

SELECT is(
  (SELECT session_load FROM app.daily_checkins
    WHERE person_id = 'f6100000-0000-0000-0000-000000000005' AND date = current_date),
  0.000,
  'Spieler5 ohne Training: session_load ist 0, nicht NULL (Ruhetag zaehlt als 0, keine fehlende Beobachtung)'
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
