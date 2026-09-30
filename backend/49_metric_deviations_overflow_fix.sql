-- =============================================================================
-- 49_metric_deviations_overflow_fix.sql — Spiegel-Datei zu supabase/migrations/
-- 20260930110000_widen_metric_deviations_overflow.sql (Muster wie backend/37_
-- load_deviation_overflow_fix.sql, siehe Kopfkommentar dort).
--
-- FUND (Backlog aus backend/38_training_load.sql Zeilen 116-129, 2026-09-30
-- lokal reproduziert): app.metric_deviations.delta_pct (backend/33_baseline_
-- engine.sql, Berechnung in app.rpc_compute_deviations Zeile ~419: v_delta_pct
-- := round(delta_abs/median*100, 2)) ist numeric(6,2) (max Betrag < 10^4).
-- delta_pct hat -- anders als z (Nenner greatest(sigma, sigma_floor), also
-- nach unten gedeckelt) -- keinen Nenner-Floor, nur den Zero-Guard "WHEN
-- b.median <> 0". Eine Person mit kleinem, aber von 0 verschiedenem
-- session_load-Median (z.B. 20 = RPE 1 x 20min) und einem einzelnen
-- Ausreisser-Tag (session_load = 2020) erreicht delta_pct = 10000.00 und
-- sprengt die Spalte. Lokal reproduziert (Homebrew-Postgres-Shadow-DB,
-- Baseline median=20.000/sigma=60.000 fuer session_load): app.rpc_compute_
-- deviations bricht mit "numeric field overflow ... precision 6, scale 2
-- must round to an absolute value less than 10^4" ab. app.cron_baseline_
-- engine rechnet ALLE Personen ALLER Teams in EINER Transaktion -- ein
-- einziger ueberlaufender Wert laesst den gesamten naechtlichen 03:00-Lauf
-- fuer ALLE Teams abbrechen. Gleiche Fehlerklasse wie backend/37 (das dort
-- gefixte load_deviations.deviation ist nur die 1:1-Kopie von delta_pct,
-- nicht die Quelle -- delta_pct selbst laeuft schon vorher ueber).
--
-- FIX: delta_pct und die lokale Variable v_delta_pct in app.rpc_compute_
-- deviations auf numeric(12,2) verbreitern (10 Vorkommastellen, max Betrag
-- < 10^10) -- deckt den Extremfall ab, in dem delta_abs die volle Breite von
-- session_load (numeric(10,3)) erreicht und durch einen realistisch
-- kleinen, aber von 0 verschiedenen Median (z.B. 1) geteilt wird (~10^9),
-- plus eine volle Zehnerpotenz Sicherheitsmarge. app.load_deviations.
-- deviation (seit backend/37 numeric(9,2), max Betrag < 10^7) ist schmaler
-- als die neue delta_pct-Breite und wird in derselben Migration ebenfalls
-- auf numeric(12,2) verbreitert -- sonst verlagert sich der Ueberlauf nur
-- eine Stufe weiter in app.rpc_compute_load_deviations (backend/35_
-- load_deviation.sql), statt an der Wurzel geschlossen zu sein.
--
-- Bewusst NICHT verbreitert (Begruendung, Nachbarspalten aus dem Backlog-
-- Kommentar in backend/38): app.baselines.median/mad/sigma/p25/p75/min_val/
-- max_val und app.metric_deviations.value/delta_abs (alle numeric(8,3)) --
-- ein realistischer Tages-Trainingsumfang (rpe 1-10, duration_min 1-300 je
-- CHECK) muesste ueber 33 Einheiten an einem Tag derselben Person summieren,
-- um die Grenze von 99999.999 zu erreichen. app.metric_deviations.z
-- (numeric(6,3)) hat mit greatest(sigma, sigma_floor) einen unteren
-- Nenner-Deckel und bleibt bei realistischen Tagesumfaengen klar unter der
-- Grenze von 999.999. Siehe Migrationskommentar fuer die volle Rechnung.
--
-- Voraussetzung: backend/33_baseline_engine.sql (CREATE TABLE app.
-- metric_deviations, app.rpc_compute_deviations), backend/37_load_deviation_
-- overflow_fix.sql (app.load_deviations.deviation bereits numeric(9,2)).
-- Tests: backend/49_metric_deviations_overflow_fix.pgtap.sql.
-- =============================================================================

-- app.v_deviations_staff (backend/33_baseline_engine.sql) liest delta_pct
-- direkt (Rule _RETURN) -- muss vor dem ALTER TYPE weg und wird danach 1:1
-- wiederhergestellt (Definition identisch zu backend/33_baseline_engine.sql
-- Zeile ~209).
DROP VIEW IF EXISTS app.v_deviations_staff;

ALTER TABLE app.metric_deviations ALTER COLUMN delta_pct TYPE numeric(12,2);
ALTER TABLE app.load_deviations    ALTER COLUMN deviation TYPE numeric(12,2);

CREATE OR REPLACE VIEW app.v_deviations_staff AS
  SELECT id, team_id, person_id, metric, date, value, baseline_id, z, delta_abs, delta_pct, band, computed_at
    FROM app.metric_deviations
   WHERE metric <> 'pain_max';

CREATE OR REPLACE FUNCTION app.rpc_compute_deviations(p_person_id uuid, p_date date)
RETURNS SETOF app.metric_deviations
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  b             app.baselines%rowtype;
  v_value       numeric(8,3);
  v_z           numeric(6,3);
  v_delta_abs   numeric(8,3);
  v_delta_pct   numeric(12,2);
  v_band        text;
  v_sigma_floor numeric(8,3);
  v_ret         app.metric_deviations%rowtype;
BEGIN
  FOR b IN
    SELECT * FROM app.baselines
     WHERE person_id = p_person_id AND as_of = p_date AND status = 'ok'
  LOOP
    SELECT (to_jsonb(dc) ->> b.metric::text)::numeric INTO v_value
      FROM app.daily_checkins dc
     WHERE dc.person_id = p_person_id AND dc.date = p_date;

    IF v_value IS NULL THEN CONTINUE; END IF;

    SELECT sigma_floor INTO v_sigma_floor
      FROM app.baseline_metric_config WHERE metric = b.metric;

    v_delta_abs := round((v_value - b.median)::numeric, 3);
    v_z         := round((v_value - b.median) / greatest(b.sigma, v_sigma_floor)::numeric, 3);
    v_delta_pct := round(CASE WHEN b.median <> 0 THEN (v_delta_abs / b.median * 100) ELSE 0 END::numeric, 2);
    v_band      := CASE WHEN abs(v_z) < 1 THEN 'normal' WHEN abs(v_z) < 2 THEN 'watch' ELSE 'marked' END;

    INSERT INTO app.metric_deviations (team_id, person_id, metric, date, value,
                                       baseline_id, z, delta_abs, delta_pct, band, computed_at)
    VALUES (b.team_id, p_person_id, b.metric, p_date, v_value, b.id, v_z, v_delta_abs, v_delta_pct, v_band, now())
    ON CONFLICT (person_id, metric, date)
    DO UPDATE SET value = EXCLUDED.value, baseline_id = EXCLUDED.baseline_id, z = EXCLUDED.z,
                  delta_abs = EXCLUDED.delta_abs, delta_pct = EXCLUDED.delta_pct,
                  band = EXCLUDED.band, computed_at = now();

    SELECT * INTO v_ret FROM app.metric_deviations
     WHERE person_id = p_person_id AND metric = b.metric AND date = p_date;
    RETURN NEXT v_ret;
  END LOOP;
  RETURN;
END;
$$;
