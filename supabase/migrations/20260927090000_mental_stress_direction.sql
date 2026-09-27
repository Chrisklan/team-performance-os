-- =============================================================================
-- 20260927090000_mental_stress_direction.sql
--
-- FUND (2026-09-27, per Analyse-Agent + eigener Verifikation ueber Supabase-MCP,
-- Projekt sxpfetwrqqwqijapgkcd/tpos-pilot): app.baseline_metric_config und die
-- eine bereits vorhandene Zeile in app.baselines tragen fuer mental_stress die
-- Richtung 'higher_better'. Das ist falsch -- mental_stress ist eine 1..10
-- Skala "wie sehr angespannt", bei der ein HOEHERER Wert SCHLECHTER ist (mehr
-- Anspannung), nicht besser. Die korrekte Richtung ist 'lower_better', exakt
-- wie bei pain_max. Die Baseline-Engine (backend/33_baseline_engine.sql) und
-- der Readiness-Score (backend/34_readiness_score.sql, app._compute_readiness_
-- score) lesen direction aus app.baseline_metric_config und invertieren den
-- z-Score nur bei 'lower_better' -- mit 'higher_better' zeigte der Faktor
-- "mental" bei HOHER Anspannung einen zu GUTEN (hohen) Punktwert, das Gegenteil
-- der Absicht.
--
-- Chris' Entscheidung (2026-09-27): Wortwahl app-weit auf "Mentale Anspannung"
-- vereinheitlichen (nicht "Stress", nicht "Gelassenheit"). Der interne Feld-/
-- Spaltenname mental_stress/p_mental_stress bleibt unveraendert (nur Anzeige).
--
-- VORAB-CHECK (Pflicht vor dieser Migration, siehe Auftrag): app.readiness_score
-- (v1, Singular) hatte zum Zeitpunkt dieser Migration 0 Zeilen (verifiziert per
-- SELECT count(*) ueber Supabase-MCP, 2026-09-27) -- keine rueckwirkend falsch
-- berechnete Zeile betroffen, keine Neuberechnung noetig. app.readiness_scores
-- (Plural, die alte, unabhaengige Bandformel "10 - mental_stress" aus backend/
-- 11_checkin_submit.sql/backend/20_denial_answer.sql) liest app.baseline_metric_
-- config NICHT und ist von dieser Migration nicht betroffen (582 Zeilen, bleiben
-- unveraendert korrekt).
--
-- app.statement_catalog (Schluessel mental_stress.above/mental_stress.below)
-- wurde separat live in der Cloud verifiziert: dort steht bereits "Mentale
-- Anspannung {delta_abs} Punkte ueber/unter der eigenen Norm" (siehe backend/
-- 35_load_deviation.sql Zeile 195-196) -- keine Korrektur in dieser Migration
-- noetig.
--
-- Idempotent (WHERE direction <> 'lower_better', bei erneutem Lauf 0 Zeilen
-- betroffen). Siehe backend/36_mental_stress_direction.sql (Spiegel-Datei) und
-- backend/36_mental_stress_direction.pgtap.sql (Regressionstest).
-- =============================================================================

UPDATE app.baseline_metric_config SET direction = 'lower_better'
 WHERE metric = 'mental_stress' AND direction <> 'lower_better';

UPDATE app.baselines SET direction = 'lower_better'
 WHERE metric = 'mental_stress' AND direction <> 'lower_better';
