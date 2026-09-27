-- =============================================================================
-- 37_load_deviation_overflow_fix.pgtap.sql — Regressionstest fuer den
-- numeric-overflow-Fix (backend/37_load_deviation_overflow_fix.sql /
-- supabase/migrations/20260927100000_fix_load_deviation_overflow.sql).
--
-- Baut eine Baseline mit median nahe Null (0.05), sodass delta_pct in
-- app.metric_deviations (numeric(6,2), z.B. 3900.00) den alten Wertebereich
-- von app.load_deviations.deviation (numeric(5,2), max Betrag < 10^3)
-- sprengen wuerde. Prueft, dass app.rpc_compute_load_deviations dabei OHNE
-- Fehler durchlaeuft und die Zeile mit dem vollen (nicht abgeschnittenen)
-- Wert geschrieben wird. Reproduziert exakt den Trockenlauf-Absturz aus
-- scripts/backfill-deviations.sql (numeric field overflow, precision 5,
-- scale 2).
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(3);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f7000000-0000-0000-0000-000000000001','Team F7','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f7100000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','Spieler F7','stuermer','f7100000-0000-0000-0000-000000000001',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f7000000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

-- median nahe Null: ein Check-in-Wert weit ueber der eigenen Norm erzeugt
-- einen delta_pct-Wert >= 1000, der vor dem Fix in load_deviations.deviation
-- (numeric(5,2)) nicht mehr passt.
INSERT INTO app.baselines (id, team_id, person_id, metric, as_of, window_days, n_obs, median, sigma, status, direction) VALUES
  ('f7200000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','pain_max','2026-09-10',28,28,0.05,0.05,'ok','lower_better');

INSERT INTO app.daily_checkins (team_id, person_id, date, pain_max) VALUES
  ('f7000000-0000-0000-0000-000000000001','f7100000-0000-0000-0000-000000000001','2026-09-10', 2);

SELECT app.rpc_compute_deviations('f7100000-0000-0000-0000-000000000001','2026-09-10');

-- -----------------------------------------------------------------------------
-- 1. Gegenprobe: delta_pct in metric_deviations liegt tatsaechlich ueber der
--    alten load_deviations-Grenze von 999.99 (sonst waere der Test wirkungslos).
-- -----------------------------------------------------------------------------
SELECT cmp_ok(
  (SELECT abs(delta_pct) FROM app.metric_deviations
    WHERE person_id = 'f7100000-0000-0000-0000-000000000001' AND metric = 'pain_max' AND date = '2026-09-10'),
  '>', 999.99::numeric,
  'Testdaten: |delta_pct| liegt ueber der alten load_deviations-Grenze (999.99)'
);

-- -----------------------------------------------------------------------------
-- 2. rpc_compute_load_deviations laeuft ohne "numeric field overflow" durch
--    und schreibt eine Zeile.
-- -----------------------------------------------------------------------------
SELECT lives_ok(
  $$SELECT app.rpc_compute_load_deviations('2026-09-10')$$,
  'rpc_compute_load_deviations wirft keinen numeric-overflow-Fehler mehr (Fund 1, Spiegel 09_rpcs.sql/35_load_deviation.sql)'
);

-- -----------------------------------------------------------------------------
-- 3. Die geschriebene Zeile traegt den vollen, unveraenderten delta_pct-Wert
--    (nicht stillschweigend abgeschnitten/gerundet auf die alte Breite).
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT deviation FROM app.load_deviations
    WHERE person_id = 'f7100000-0000-0000-0000-000000000001' AND metric = 'pain_max' AND date = '2026-09-10'),
  (SELECT delta_pct FROM app.metric_deviations
    WHERE person_id = 'f7100000-0000-0000-0000-000000000001' AND metric = 'pain_max' AND date = '2026-09-10'),
  'load_deviations.deviation entspricht 1:1 dem vollen metric_deviations.delta_pct-Wert'
);

SELECT * FROM finish();
ROLLBACK;
