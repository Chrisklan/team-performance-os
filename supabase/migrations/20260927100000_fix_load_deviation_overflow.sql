-- =============================================================================
-- 20260927100000_fix_load_deviation_overflow.sql
--
-- FUND 1 (2026-09-27, Trockenlauf scripts/backfill-deviations.sql, BEGIN;...
-- ROLLBACK; gegen 582 echte Check-ins, Abbruch mit "numeric field overflow"):
-- app.load_deviations.deviation ist numeric(5,2) (max Betrag < 10^3, also
-- ±999.99), definiert in backend/09_rpcs.sql (CREATE TABLE IF NOT EXISTS
-- app.load_deviations). backend/35_load_deviation.sql erweitert die Tabelle
-- seither nur um metric/streak_days/days_out_7/z_mean_7/trend_slope_7/
-- magnitude/statement_key (siehe dortiger Abschnitt 1) -- deviation selbst
-- wurde nie angefasst.
--
-- app.metric_deviations.delta_pct (backend/33_baseline_engine.sql, Tabellen-
-- definition Zeile ~188, Berechnung app.rpc_compute_deviations Zeile ~393/413:
-- v_delta_pct numeric(6,2) := round((v_delta_abs/b.median*100), 2) wenn
-- b.median <> 0) ist numeric(6,2) (max Betrag < 10^4, also ±9999.99) -- also
-- strukturell breiter als load_deviations.deviation.
--
-- app.rpc_compute_load_deviations (backend/35_load_deviation.sql, INSERT INTO
-- app.load_deviations ... VALUES (..., COALESCE(r.delta_pct, 0), ...))
-- kopiert delta_pct 1:1 in deviation. Jeder delta_pct-Wert mit Betrag >= 1000
-- (in metric_deviations gueltig, siehe obige Grenze) sprengt load_deviations.
-- Lokal reproduziert (tpos_gate_test_loaddev, Baseline median=0.05, sigma=0.05,
-- Check-in-Wert 2 -> delta_pct=3900.00, z=2.438): app.rpc_compute_load_
-- deviations bricht mit exakt "numeric field overflow ... precision 5, scale 2
-- must round to an absolute value less than 10^3" ab -- derselbe Fehler wie im
-- Trockenlauf. Betrifft nicht nur den Backfill, sondern auch den echten
-- naechtlichen Cron-Job (app.cron_loaddeviation, aktiv seit Migration
-- 20260927082030_wire_baseline_loaddeviation_cron.sql, 03:30 Uhr).
--
-- FIX: deviation auf numeric(9,2) verbreitern -- deckt den vollen Wertebereich
-- von delta_pct (numeric(6,2), max ±9999.99) plus Sicherheitsmarge fuer
-- kuenftige Aenderungen ab. Per ALTER TABLE, die bestehende CREATE TABLE in
-- backend/09_rpcs.sql wird nicht rueckwirkend geaendert (Projektkonvention,
-- siehe z.B. backend/35_load_deviation.sql Abschnitt 1 fuer denselben Ansatz
-- bei metric/streak_days/etc.). Spiegel-Datei: backend/37_load_deviation_
-- overflow_fix.sql, Regressionstest: backend/37_load_deviation_overflow_fix.
-- pgtap.sql.
--
-- FUND 2 (Datenfehler, gemessen ueber Supabase-MCP gegen Projekt
-- sxpfetwrqqwqijapgkcd/tpos-pilot, 2026-09-27): Person a0000000-0000-0000-
-- 0000-000000000001 (Maximilian Krueger, Torwart #1, Team 11111111-1111-1111-
-- 1111-111111111111) hat in app.daily_checkins bei sleep_duration_min an vier
-- von 31 Tagen die Einheit verwechselt (Minuten statt Stunden eingetragen),
-- waehrend die uebrigen 27 Tage korrekt in Stunden stehen (Spanne 6.52-9.00):
--   2026-09-19: 450.00 -> 7.50  (450/60)
--   2026-09-20: 300.00 -> 5.00  (300/60)
--   2026-09-21: 480.00 -> 8.00  (480/60)
--   2026-09-26: 480.00 -> 8.00  (480/60)
-- Die korrigierten Werte (5.00/7.50/8.00/8.00) passen in die Spanne der
-- uebrigen 27 Tage dieser Person -- belegte, systematische Einheiten-
-- korrektur (durch 60 teilen), kein Raten eines unbekannten Werts.
--
-- FIX: vier gezielte UPDATEs, WHERE-Bedingung zusaetzlich auf den aktuellen
-- falschen Wert (idempotent -- ein erneuter Lauf aendert 0 Zeilen, weil der
-- Wert dann schon korrigiert ist).
--
-- Beide Funde unabhaengig voneinander, in einer Migration zusammengefasst,
-- weil beide am selben Trockenlauf (scripts/backfill-deviations.sql) haengen
-- geblieben sind und derselbe PM-Auftrag sie beide behebt.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Fund 1: load_deviations.deviation verbreitern
-- -----------------------------------------------------------------------------
ALTER TABLE app.load_deviations ALTER COLUMN deviation TYPE numeric(9,2);

-- -----------------------------------------------------------------------------
-- 2. Fund 2: Einheiten-Korrektur sleep_duration_min, Maximilian Krueger
-- -----------------------------------------------------------------------------
UPDATE app.daily_checkins SET sleep_duration_min = 7.50
 WHERE person_id = 'a0000000-0000-0000-0000-000000000001' AND date = '2026-09-19' AND sleep_duration_min = 450.00;

UPDATE app.daily_checkins SET sleep_duration_min = 5.00
 WHERE person_id = 'a0000000-0000-0000-0000-000000000001' AND date = '2026-09-20' AND sleep_duration_min = 300.00;

UPDATE app.daily_checkins SET sleep_duration_min = 8.00
 WHERE person_id = 'a0000000-0000-0000-0000-000000000001' AND date = '2026-09-21' AND sleep_duration_min = 480.00;

UPDATE app.daily_checkins SET sleep_duration_min = 8.00
 WHERE person_id = 'a0000000-0000-0000-0000-000000000001' AND date = '2026-09-26' AND sleep_duration_min = 480.00;
