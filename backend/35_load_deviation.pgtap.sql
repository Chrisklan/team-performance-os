-- =============================================================================
-- 35_load_deviation.pgtap.sql — LoadDeviation (Bridge Punkt 57, Teil 3 von 3)
--
-- Prueft backend/35_load_deviation.sql: metric-Spalte und Unique-Constraint,
-- rpc_compute_load_deviations (Persistenzkennzahlen aus echten metric_
-- deviations-Reihen, Ausschluss von energy/training_readiness, Idempotenz
-- ohne Zuruecksetzen von state), Sichtbarkeit (self/staff gefiltert/medical,
-- pain_max nie fuer Staff), Textbaustein-Aufloesung, module_flags (nur
-- doctor setzt, MODULE_DISABLED ohne Freischaltung), rpc_get_deviations_today,
-- Blacklist-Test auf dem Textbaustein-Katalog.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(26);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f5000000-0000-0000-0000-000000000001','Team F5','Europe/Berlin'),
  ('f5000000-0000-0000-0000-000000000009','Team F5b (fremd)','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f5100000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-000000000001','Spielerin F5','stuermerin','f5100000-0000-0000-0000-000000000001',true),
  ('f5100000-0000-0000-0000-000000000002','f5000000-0000-0000-0000-000000000001','Coach F5','coach','f5100000-0000-0000-0000-000000000002',true),
  ('f5100000-0000-0000-0000-000000000003','f5000000-0000-0000-0000-000000000001','Physio F5','physio','f5100000-0000-0000-0000-000000000003',true),
  ('f5100000-0000-0000-0000-000000000004','f5000000-0000-0000-0000-000000000001','Arzt F5','doctor','f5100000-0000-0000-0000-000000000004',true),
  ('f5100000-0000-0000-0000-000000000009','f5000000-0000-0000-0000-000000000009','Fremde Spielerin','stuermerin','f5100000-0000-0000-0000-000000000009',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL),
  ('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000002','coach', now() - interval '90 days', NULL),
  ('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000003','physio', now() - interval '90 days', NULL),
  ('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000004','doctor', now() - interval '90 days', NULL),
  ('f5000000-0000-0000-0000-000000000009','f5100000-0000-0000-0000-000000000009','player', now() - interval '90 days', NULL);

CREATE OR REPLACE FUNCTION app._t35_jwt(p_sub text, p_role text, p_team text DEFAULT 'f5000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- -----------------------------------------------------------------------------
-- 1. Struktur: metric-Spalte, Unique auf (person_id, metric, date)
-- -----------------------------------------------------------------------------
SELECT has_column('app', 'load_deviations', 'metric', 'load_deviations hat eine metric-Spalte (Fund 1)');
SELECT ok(
  EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'load_deviations_person_metric_date_key'),
  'Unique-Constraint ist auf (person_id, metric, date), nicht mehr (person_id, date)'
);

-- -----------------------------------------------------------------------------
-- 2. Fixture: echte Baseline + 7 Tage Abweichung ueber die reale Engine
--    (sleep_duration_min stark abweichend, energy leicht abweichend als
--    Ausschluss-Probe, pain_max stark abweichend fuer die Medizin-Domaene).
-- -----------------------------------------------------------------------------
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, energy, pain_max)
SELECT 'f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001',
       '2026-09-10'::date - g, 480, 1, 1
FROM generate_series(7, 34) g;

-- energy weicht hier ebenfalls stark ab (1 -> 4, sigma_floor 0.4 -> |z| gross):
-- der Ausschluss von energy aus LoadDeviation ist damit ein echter Fund des
-- Metrik-Filters, nicht nur Zufall einer konstanten Reihe.
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, energy, pain_max)
SELECT 'f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001',
       '2026-09-10'::date - g, 300, 4, 6
FROM generate_series(0, 6) g;

DO $$
DECLARE d date;
BEGIN
  FOR d IN SELECT '2026-09-10'::date - g FROM generate_series(0, 6) g LOOP
    PERFORM app._compute_baseline('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001','sleep_duration_min', d);
    PERFORM app._compute_baseline('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001','pain_max', d);
    PERFORM app._compute_baseline('f5000000-0000-0000-0000-000000000001','f5100000-0000-0000-0000-000000000001','energy', d);
    PERFORM app.rpc_compute_deviations('f5100000-0000-0000-0000-000000000001', d);
  END LOOP;
END $$;

-- Vorbedingung fuer den Ausschluss-Test unten: energy weicht in metric_
-- deviations selbst tatsaechlich ab (sonst waere "keine load_deviations-
-- Zeile" nur Zufall einer unauffaelligen Reihe, kein echter Fund des Filters).
SELECT ok(
  EXISTS (SELECT 1 FROM app.metric_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'energy' AND date = '2026-09-10' AND abs(z) >= 1),
  'Vorbedingung: energy weicht in metric_deviations tatsaechlich ab (|z| >= 1)'
);

SELECT app.rpc_compute_load_deviations('2026-09-10');

-- -----------------------------------------------------------------------------
-- 3. Persistenzkennzahlen korrekt aus der echten metric_deviations-Reihe
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT streak_days FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10'),
  7, 'streak_days = 7 (alle 7 Tage abweichend)'
);
SELECT is(
  (SELECT days_out_7 FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10'),
  7, 'days_out_7 = 7'
);
SELECT is(
  (SELECT statement_key FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10'),
  'sleep_duration_min.below', 'statement_key: 300 < Baseline -> .below'
);

-- energy erzeugt keine load_deviations-Zeile (weder wegen Ausschluss noch weil
-- konstant -- siehe oben; der Ausschluss selbst steht in der WHERE-Klausel von
-- rpc_compute_load_deviations und ist durch den Metrik-Filter erzwungen).
SELECT ok(
  NOT EXISTS (SELECT 1 FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'energy'),
  'energy (nicht Teil der LoadDeviation-Metrikliste) erzeugt nie eine Zeile'
);

-- pain_max weicht ab (1 -> 6) und ist Teil der Liste, MUSS eine Zeile erzeugen.
SELECT ok(
  EXISTS (SELECT 1 FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'pain_max' AND date = '2026-09-10'),
  'pain_max erzeugt eine Zeile (Domaenen-Gate ist Sichtbarkeit, nicht Existenz)'
);

-- -----------------------------------------------------------------------------
-- 4. Idempotenz: ein zweiter Nachtlauf darf eine bereits gesichtete Zeile
--    nicht auf unreviewed zuruecksetzen.
-- -----------------------------------------------------------------------------
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000003', 'physio');
SELECT public.rpc_review_deviation(
  (SELECT id FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10'),
  'release'
);

SELECT app.rpc_compute_load_deviations('2026-09-10');

SELECT is(
  (SELECT state FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10')::text,
  'released', 'ein zweiter Nachtlauf setzt eine bereits freigegebene Zeile NICHT auf unreviewed zurueck'
);

-- -----------------------------------------------------------------------------
-- 5. module_flags: ohne Freischaltung wirft jede lesende Tuer MODULE_DISABLED
-- -----------------------------------------------------------------------------
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000001', 'player');
SELECT throws_ok(
  $$ SELECT app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000001', NULL, NULL) $$,
  NULL, 'MODULE_DISABLED',
  'ohne Freischaltung: rpc_get_person_deviations wirft MODULE_DISABLED, auch fuer self'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)),
  'coach darf das Modul-Flag nicht setzen (nur doctor)'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000004', 'doctor');
SELECT ok(
  NOT app.is_denial(app.rpc_set_module_flag('loaddeviation_enabled', true)),
  'doctor darf das Modul-Flag setzen'
);
SELECT ok(
  app.rpc_get_module_flag('loaddeviation_enabled'),
  'rpc_get_module_flag liest die eigene Team-Freischaltung zurueck'
);

-- -----------------------------------------------------------------------------
-- 6. Sichtbarkeit ueber rpc_get_person_deviations (jetzt freigeschaltet)
-- -----------------------------------------------------------------------------
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000001', 'player');
SELECT ok(
  jsonb_array_length(app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000001', NULL, NULL)) >= 2,
  'self sieht die eigenen Zeilen (sleep_duration_min released, pain_max unreviewed)'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (
    SELECT count(*) FROM jsonb_array_elements(app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000001', NULL, NULL)) x
     WHERE x ->> 'metric' = 'pain_max'
  )::int,
  0, 'Staff sieht pain_max NIE, auch nicht nach Freigabe einer anderen Metrik'
);
SELECT is(
  (
    SELECT count(*) FROM jsonb_array_elements(app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000001', NULL, NULL)) x
     WHERE x ->> 'metric' = 'sleep_duration_min'
  )::int,
  1, 'Staff sieht sleep_duration_min NACH der Freigabe (state=released)'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000003', 'physio');
SELECT is(
  (
    SELECT count(*) FROM jsonb_array_elements(app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000001', NULL, NULL)) x
     WHERE x ->> 'metric' = 'pain_max'
  )::int,
  1, 'Medizin sieht pain_max, auch unreviewed'
);

-- Fremdes Team: die Zielperson ist keine Spielerin des eigenen Teams.
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  app.is_denial(app.rpc_get_person_deviations('f5100000-0000-0000-0000-000000000009', NULL, NULL)),
  'Coach aus Team F5 bekommt fuer eine fremde Spielerin (Team F5b) eine Ablehnung'
);

-- -----------------------------------------------------------------------------
-- 7. Textbaustein-Aufloesung
-- -----------------------------------------------------------------------------
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000001', 'player');
SELECT ok(
  app.rpc_get_deviation_statement(
    (SELECT id FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'sleep_duration_min' AND date = '2026-09-10')
  ) LIKE 'Schlafdauer%unter der eigenen Norm',
  'Textbaustein fuer sleep_duration_min.below ist korrekt aufgeloest'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000002', 'coach');
SELECT throws_ok(
  $$
    SELECT app.rpc_get_deviation_statement(
      (SELECT id FROM app.load_deviations WHERE person_id = 'f5100000-0000-0000-0000-000000000001' AND metric = 'pain_max' AND date = '2026-09-10')
    )
  $$,
  'P0002', NULL,
  'Coach bekommt fuer den Textbaustein einer pain_max-Zeile P0002 (dieselbe Antwort wie "nicht gefunden")'
);

-- -----------------------------------------------------------------------------
-- 8. rpc_get_deviations_today: Staff gefiltert, Medizin vollstaendig
-- -----------------------------------------------------------------------------
SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (
    SELECT count(*) FROM jsonb_array_elements(app.rpc_get_deviations_today('2026-09-10')) p,
                         jsonb_array_elements(p -> 'deviations') d
     WHERE d ->> 'metric' = 'pain_max'
  )::int,
  0, 'rpc_get_deviations_today: Staff sieht pain_max nie'
);

SELECT app._t35_jwt('f5100000-0000-0000-0000-000000000003', 'physio');
SELECT is(
  (
    SELECT count(*) FROM jsonb_array_elements(app.rpc_get_deviations_today('2026-09-10')) p,
                         jsonb_array_elements(p -> 'deviations') d
     WHERE d ->> 'metric' = 'pain_max'
  )::int,
  1, 'rpc_get_deviations_today: Medizin sieht pain_max'
);

-- -----------------------------------------------------------------------------
-- 9. Blacklist (ADR-006 G-01): kein Textbaustein enthaelt verbotene Woerter
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int FROM app.statement_catalog
    WHERE template ~* 'risiko|gefahr|prognose|vorhersage|wahrscheinlich|droht|sollte|empfehl|reduzier|warnung'),
  0, 'kein Textbaustein im Katalog verstoesst gegen die Sperrliste (G-01)'
);
SELECT is(
  (SELECT count(*)::int FROM app.statement_catalog WHERE template LIKE '%-%'),
  0, 'kein Textbaustein enthaelt einen Bindestrich'
);

-- -----------------------------------------------------------------------------
-- 10. Strukturelle Isolation: authenticated hat kein direktes Recht auf
--     module_flags (Cross-Team-Leck-Schutz, siehe Migrationskopf Fund 3).
-- -----------------------------------------------------------------------------
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.module_flags', 'SELECT'),
  'authenticated hat strukturell 0 SELECT-Recht auf app.module_flags'
);
SELECT ok(
  NOT has_table_privilege('anon', 'app.module_flags', 'SELECT'),
  'anon hat strukturell 0 SELECT-Recht auf app.module_flags'
);

SELECT * FROM finish();
ROLLBACK;
