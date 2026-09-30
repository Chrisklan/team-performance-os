-- =============================================================================
-- 20260930110000_widen_metric_deviations_overflow.sql
--
-- FUND (2026-09-30, Backlog-Eintrag aus backend/38_training_load.sql
-- Zeilen 116-129, jetzt lokal reproduziert, siehe backend/49_metric_deviations_
-- overflow_fix.pgtap.sql): app.daily_checkins.session_load ist numeric(10,3)
-- (bis 9 999 999,999, backend/38_training_load.sql Fund 5). Die Baseline-
-- Engine (backend/33_baseline_engine.sql, app.rpc_compute_deviations, ca.
-- Zeile 388-430) berechnet daraus v_delta_pct := round(delta_abs / median *
-- 100, 2) und schreibt das nach app.metric_deviations.delta_pct, das nur
-- numeric(6,2) ist (max Betrag < 10^4, also < 10000.00%).
--
-- Anders als bei z (dividiert durch greatest(sigma, sigma_floor), also durch
-- einen nach unten gedeckelten Nenner) hat delta_pct KEINEN Nenner-Floor --
-- nur den Zero-Guard "WHEN b.median <> 0". Eine Person mit kleinem, aber von
-- 0 verschiedenem Last-Median (z.B. 20 = RPE 1 x 20min, realistisch bei
-- leichtem/individuellem Training) und einem einzelnen Ausreisser-Tag
-- (z.B. session_load = 2020) erreicht delta_pct = 10000.00 und sprengt die
-- Spalte. Lokal reproduziert (Homebrew-Postgres-Shadow-DB, Baseline
-- median=20.000/sigma=60.000 fuer session_load, Check-in-Wert 2020 fuer
-- denselben Tag): app.rpc_compute_deviations bricht mit exakt "numeric field
-- overflow ... precision 6, scale 2 must round to an absolute value less
-- than 10^4" ab.
--
-- app.cron_baseline_engine berechnet ALLE Personen ALLER Teams in EINER
-- Transaktion (backend/33_baseline_engine.sql) -- ein einziger ueberlaufender
-- Wert einer einzigen Person laesst den KOMPLETTEN naechtlichen 03:00-Lauf
-- fuer ALLE Teams abbrechen, nicht nur fuer die betroffene Person/das
-- betroffene Team. Gleiche Fehlerklasse wie backend/37_load_deviation_
-- overflow_fix.sql (dort wurde app.load_deviations.deviation, die 1:1-Kopie
-- von delta_pct, verbreitert -- das behob nur die Kopie, nicht die Quelle.
-- delta_pct selbst laeuft schon VOR der Kopie ueber).
--
-- FIX: app.metric_deviations.delta_pct und die lokale Variable v_delta_pct
-- in app.rpc_compute_deviations (backend/33_baseline_engine.sql) auf
-- numeric(12,2) verbreitern. Begruendung der Breite: v_delta_abs kann im
-- Extremfall die volle Breite von session_load (numeric(10,3), 7 Vorkomma-
-- stellen) erreichen; bei einem realistisch kleinen, aber von 0
-- verschiedenen Median (z.B. 1, ein einzelner minimaler Trainingstag)
-- ergibt delta_abs/median*100 rechnerisch bis zu ca. 10^9 (9 Vorkomma-
-- stellen). numeric(12,2) (10 Vorkommastellen, max Betrag < 10^10) deckt
-- das mit einer vollen Zehnerpotenz Sicherheitsmarge ab, analog zur
-- Begruendung in backend/37 (Zielbreite deckt die tatsaechliche
-- Quellspaltenbreite plus Marge, kein beliebig grosser Puffer ins Blaue).
--
-- Nachbarspalten aus dem Backlog-Kommentar (backend/38, Zeilen 118-121)
-- gegen dieselbe Erreichbarkeits-Frage geprueft, mit realistischen Werten
-- (grosser session_load-Range, siehe unten) -- BEWUSST NICHT in dieser
-- Migration verbreitert:
--   * app.baselines.median/mad/sigma/p25/p75/min_val/max_val (numeric(8,3),
--     max Betrag < 10^5) und app.metric_deviations.value/delta_abs
--     (ebenfalls numeric(8,3)): v_value wird direkt aus session_load
--     gelesen (Variable in rpc_compute_deviations ist selbst schon
--     numeric(8,3) deklariert). Ein realistischer Tages-Trainingsumfang
--     (session_rpe: rpe 1-10, duration_min 1-300 je CHECK-Constraint in
--     backend/38_training_load.sql, also max. 3000 Last je Einheit) muesste
--     ueber 33 Einheiten AN EINEM TAG derselben Person summieren, um die
--     Grenze von 99999.999 zu erreichen -- weit ausserhalb jedes
--     realistischen Trainingsplans. Bleibt unveraendert.
--   * app.metric_deviations.z (numeric(6,3), max Betrag < 1000): z hat mit
--     greatest(sigma, sigma_floor) im Nenner (sigma_floor fuer session_load
--     = 60.000, backend/33_baseline_engine.sql) einen unteren Deckel --
--     genau der Schutz, den delta_pct nicht hat. Selbst am oben beschriebenen
--     realistischen Limit (Betrag knapp unter 99999.999) bleibt |z| < 1700,
--     bei realistischen Tagesumfaengen (wenige Einheiten, nicht 33) klar
--     unter 1000. Bleibt unveraendert.
--
-- Kapazitaets-Gegenprobe (Auftrag Schritt 2): app.load_deviations.deviation
-- ist seit backend/37 numeric(9,2) (max Betrag < 10^7) -- schmaler als die
-- neue delta_pct-Breite numeric(12,2) (max Betrag < 10^10). Ohne Fix wuerde
-- der Overflow nur eine Stufe weiter in app.rpc_compute_load_deviations
-- (backend/35_load_deviation.sql, COALESCE(r.delta_pct, 0)-Kopie) verlagert,
-- nicht geschlossen. Deshalb wird load_deviations.deviation in derselben
-- Migration auf denselben Zieltyp numeric(12,2) verbreitert.
--
-- Sicherheitsfragen (Report-Pflicht, siehe Task-Brief):
-- (a) Keine CHECK-Constraints auf delta_pct/deviation/v_delta_pct, die sich
--     auf die alte Praezision verlassen (verifiziert per Grep gegen
--     backend/33_baseline_engine.sql, backend/35_load_deviation.sql,
--     backend/09_rpcs.sql, backend/schema.sql -- keine Treffer).
-- (b) Reine Typ-Verbreiterung, keine Aenderung an app.cron_baseline_engine,
--     app.rpc_compute_deviations oder app.rpc_compute_load_deviations
--     (Query-Logik/Transaktionsgrenze/Team-Scoping unveraendert) -- die
--     Team-Isolation der Cron-Transaktion bleibt unangetastet.
--
-- Voraussetzung: backend/33_baseline_engine.sql (CREATE TABLE app.
-- metric_deviations), backend/37_load_deviation_overflow_fix.sql (app.
-- load_deviations.deviation bereits numeric(9,2)). Spiegel-Datei:
-- backend/49_metric_deviations_overflow_fix.sql, Regressionstest:
-- backend/49_metric_deviations_overflow_fix.pgtap.sql.
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
