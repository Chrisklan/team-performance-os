-- =============================================================================
-- 49_metric_deviations_overflow_fix.pgtap.sql — Regressionstest fuer den
-- numeric-overflow-Fix (backend/49_metric_deviations_overflow_fix.sql /
-- supabase/migrations/20260930110000_widen_metric_deviations_overflow.sql).
--
-- Baut eine Baseline mit kleinem, aber von 0 verschiedenem session_load-
-- Median (20 = RPE 1 x 20min), sodass ein einzelner Ausreisser-Tag
-- (session_load=2020) delta_pct=10000.00 erzeugt -- genau die Grenze, an der
-- der alte Typ numeric(6,2) (max Betrag < 10^4) mit "numeric field overflow"
-- abbricht. Reproduziert exakt den Befund aus backend/38_training_load.sql
-- Zeilen 116-129. Prueft zusaetzlich, dass ein Ueberlauf bei EINER Person
-- die Baseline-Berechnung einer ANDEREN Person/eines ANDEREN Teams in
-- derselben Transaktion nicht verhindert (Teil des DONE_WHEN).
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(6);

-- -----------------------------------------------------------------------------
-- Team E8: Ausreisser-Fall (kleiner Median, extremer Tageswert)
-- -----------------------------------------------------------------------------
INSERT INTO app.teams (id, name, timezone) VALUES
  ('e8000000-0000-0000-0000-000000000001','Team E8','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('e8100000-0000-0000-0000-000000000001','e8000000-0000-0000-0000-000000000001','Spieler E8','stuermer','e8100000-0000-0000-0000-000000000001',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('e8000000-0000-0000-0000-000000000001','e8100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

INSERT INTO app.baselines (id, team_id, person_id, metric, as_of, window_days, n_obs, median, sigma, status, direction) VALUES
  ('e8200000-0000-0000-0000-000000000001','e8000000-0000-0000-0000-000000000001','e8100000-0000-0000-0000-000000000001','session_load','2026-09-10',28,28,20.000,60.000,'ok','neutral');

INSERT INTO app.daily_checkins (team_id, person_id, date, session_load) VALUES
  ('e8000000-0000-0000-0000-000000000001','e8100000-0000-0000-0000-000000000001','2026-09-10', 2020);

-- -----------------------------------------------------------------------------
-- Team E9: normaler Fall, ANDERES Team, GLEICHES Datum -- Kontrollgruppe fuer
-- die Team-Isolations-Frage (b) und fuer den Cron-Transaktions-Test.
-- -----------------------------------------------------------------------------
INSERT INTO app.teams (id, name, timezone) VALUES
  ('e9000000-0000-0000-0000-000000000001','Team E9','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('e9100000-0000-0000-0000-000000000001','e9000000-0000-0000-0000-000000000001','Spieler E9','stuermer','e9100000-0000-0000-0000-000000000001',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('e9000000-0000-0000-0000-000000000001','e9100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

INSERT INTO app.baselines (id, team_id, person_id, metric, as_of, window_days, n_obs, median, sigma, status, direction) VALUES
  ('e9200000-0000-0000-0000-000000000001','e9000000-0000-0000-0000-000000000001','e9100000-0000-0000-0000-000000000001','session_load','2026-09-10',28,28,500.000,150.000,'ok','neutral');

INSERT INTO app.daily_checkins (team_id, person_id, date, session_load) VALUES
  ('e9000000-0000-0000-0000-000000000001','e9100000-0000-0000-0000-000000000001','2026-09-10', 650);

-- -----------------------------------------------------------------------------
-- 1. Gegenprobe: delta_pct fuer Team E8 liegt tatsaechlich auf/ueber der
--    alten metric_deviations-Grenze von 9999.99 (sonst waere der Test
--    wirkungslos -- ohne diese Zeile koennte die Suite auch bei nicht
--    gefixtem Code faelschlich gruen sein, weil die Testdaten zu klein sind).
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.rpc_compute_deviations('e8100000-0000-0000-0000-000000000001','2026-09-10')$$,
  'rpc_compute_deviations wirft keinen numeric-overflow-Fehler mehr fuer den Ausreisser-Fall (Team E8, delta_pct=10000.00)'
);

SELECT cmp_ok(
  (SELECT abs(delta_pct) FROM app.metric_deviations
    WHERE person_id = 'e8100000-0000-0000-0000-000000000001' AND metric = 'session_load' AND date = '2026-09-10'),
  '>=', 9999.99::numeric,
  'Testdaten: |delta_pct| liegt auf/ueber der alten metric_deviations-Grenze (9999.99) -- Gegenprobe waere ohne Fix mit numeric field overflow abgebrochen'
);

-- -----------------------------------------------------------------------------
-- 2. Der volle, unveraenderte Wert wird geschrieben (nicht stillschweigend
--    abgeschnitten/gerundet auf die alte Breite).
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT delta_pct FROM app.metric_deviations
    WHERE person_id = 'e8100000-0000-0000-0000-000000000001' AND metric = 'session_load' AND date = '2026-09-10'),
  10000.00::numeric,
  'metric_deviations.delta_pct traegt den vollen, nicht abgeschnittenen Wert (10000.00)'
);

-- -----------------------------------------------------------------------------
-- 3. Team-Isolation / Cron-Transaktion (DONE_WHEN): der Ausreisser bei Team
--    E8 verhindert NICHT die Baseline-Berechnung fuer Team E9 in derselben
--    Transaktion (dieselbe Transaktion wie app.cron_baseline_engine sie
--    verwendet, hier durch das gemeinsame BEGIN/ROLLBACK der Suite
--    nachgebildet -- beide RPC-Aufrufe laufen in genau einer Transaktion).
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.rpc_compute_deviations('e9100000-0000-0000-0000-000000000001','2026-09-10')$$,
  'rpc_compute_deviations fuer Team E9 (anderes Team, gleiche Transaktion) laeuft nach dem Ausreisser von Team E8 unveraendert durch'
);

SELECT is(
  (SELECT delta_pct FROM app.metric_deviations
    WHERE person_id = 'e9100000-0000-0000-0000-000000000001' AND metric = 'session_load' AND date = '2026-09-10'),
  30.00::numeric,
  'metric_deviations.delta_pct fuer Team E9 ist korrekt und unbeeinflusst vom Ausreisser bei Team E8 ((650-500)/500*100=30.00)'
);

-- -----------------------------------------------------------------------------
-- 4. Kapazitaets-Kette: app.rpc_compute_load_deviations (kopiert delta_pct
--    1:1 nach load_deviations.deviation, backend/35_load_deviation.sql)
--    laeuft ebenfalls ohne Overflow durch -- die Verbreiterung von
--    load_deviations.deviation auf numeric(12,2) in derselben Migration
--    verlagert den Ueberlauf nicht nur eine Stufe weiter.
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.rpc_compute_load_deviations('2026-09-10')$$,
  'rpc_compute_load_deviations wirft keinen numeric-overflow-Fehler mehr beim Kopieren des vollen delta_pct-Werts nach load_deviations.deviation'
);

SELECT * FROM finish();
ROLLBACK;
