-- scripts/backfill-deviations.sql
--
-- Backfill fuer app.baselines / app.metric_deviations / app.load_deviations,
-- nachdem der Fund vom 2026-09-27 gezeigt hat, dass die Nachtlaeufe
-- (app.rpc_recompute_baselines, app.rpc_compute_deviations,
-- app.rpc_compute_load_deviations) nie automatisch liefen -- pg_cron war in
-- der Cloud nicht installiert, kein Code im Repo hat sie je aufgerufen.
-- Die Verdrahtung selbst steht in supabase/migrations/
-- 20260927082030_wire_baseline_loaddeviation_cron.sql (app.cron_baseline_
-- engine / app.cron_loaddeviation, taeglich ab jetzt). Dieses Skript holt
-- NUR die Vergangenheit nach, einmalig, Tag fuer Tag ueber den kompletten
-- vorhandenen Check-in-Zeitraum -- exakt das, was die beiden Cron-Jobs
-- taeglich getan haetten, waeren sie von Anfang an gelaufen.
--
-- Gemessen am 2026-09-27 (read-only, vor dieser Migration): 20 Personen mit
-- Check-ins, 31 Tage mit mindestens einem Check-in, Zeitraum 2026-08-23 bis
-- 2026-09-26 (35 Kalendertage Spanne, 4 Tage darin ohne jeden Check-in),
-- 582 Check-in-Zeilen insgesamt, 25 aktive Personen im Team. Ungefaehre
-- erwartete Zeilenzahl (siehe Bericht der Session fuer die Herleitung):
--   app.baselines           ~ 25 Personen x 11 Metriken x 35 Tage ~ 9.600 Zeilen
--   app.metric_deviations   ~ mehrere Hundert (nur Tage mit Check-in UND
--                              status='ok'-Baseline, session_load/
--                              acute_chronic_ratio bleiben leer -- kein
--                              Trainingsmanagement-Modul, strukturell 0)
--   app.load_deviations     ~ eine Teilmenge davon (nur |z| >= 1, 9 der 11
--                              Metriken -- energy/training_readiness gehoeren
--                              zu Readiness-Score, nicht zu LoadDeviation)
-- Nur eine grobe Schaetzung -- die echte Zahl haengt von der Datenverteilung
-- ab und zeigt sich erst im Trockenlauf unten.
--
-- WICHTIG: NICHT ungefragt gegen die Cloud ausfuehren. Projekt-Konvention:
-- jede Cloud-Datenaenderung erst nach Trockenlauf und Freigabe im Chat durch
-- Chris. Diese Datei ist vorbereitet, aber bewusst NICHT gegen die Cloud
-- eingespielt worden (Auftrag dieser Session).
--
-- Trockenlauf zuerst (zeigt die Zeilenzahl, aendert aber nichts dauerhaft):
--   supabase db query --linked --file scripts/backfill-deviations.sql
-- mit der ROLLBACK-Zeile unten aktiv (Standard in dieser Datei).
--
-- Scharf schalten (nach Freigabe von Chris): die ROLLBACK-Zeile auskommentieren,
-- die COMMIT-Zeile aktivieren, erneut ausfuehren.
--
-- Idempotent: app.rpc_recompute_baselines/app.rpc_compute_deviations/
-- app.rpc_compute_load_deviations schreiben alle per ON CONFLICT ... DO
-- UPDATE (siehe backend/33_baseline_engine.sql, backend/35_load_deviation.sql)
-- -- ein zweiter Lauf ueber denselben Zeitraum ist sicher, keine Duplikate,
-- keine doppelten Freigabe-Zustaende (load_deviations behaelt state/reviewed_*
-- bei einem erneuten Lauf unveraendert).

BEGIN;

DO $$
DECLARE
  v_from    date;
  v_to      date;
  d         date;
  v_days    int := 0;
  r         record;
BEGIN
  SELECT min(date), max(date) INTO v_from, v_to FROM app.daily_checkins;

  IF v_from IS NULL THEN
    RAISE NOTICE 'Keine Check-ins vorhanden, nichts zu tun.';
    RETURN;
  END IF;

  RAISE NOTICE 'Backfill % bis % ...', v_from, v_to;

  d := v_from;
  WHILE d <= v_to LOOP
    -- 1. Baselines fuer diesen Tag (alle aktiven Personen, alle Metriken).
    PERFORM app.rpc_recompute_baselines(d);

    -- 2. Tagesabweichung je Person (rpc_compute_deviations hat keine
    --    All-Personen-Variante, siehe app.cron_baseline_engine in der
    --    Wiring-Migration).
    FOR r IN SELECT id AS person_id FROM app.persons WHERE is_active LOOP
      PERFORM app.rpc_compute_deviations(r.person_id, d);
    END LOOP;

    -- 3. LoadDeviation-Persistenzkennzahlen fuer denselben Tag, liest die
    --    metric_deviations aus Schritt 2 (siehe backend/35_load_deviation.sql
    --    Abschnitt 6 -- laeuft bewusst NACH den Deviations desselben Tages).
    PERFORM app.rpc_compute_load_deviations(d);

    v_days := v_days + 1;
    d := d + 1;
  END LOOP;

  RAISE NOTICE 'Backfill fertig: % Tage verarbeitet (% bis %).', v_days, v_from, v_to;
END $$;

-- Zur Kontrolle vor der Entscheidung COMMIT/ROLLBACK:
SELECT
  (SELECT count(*) FROM app.baselines)          AS baselines,
  (SELECT count(*) FROM app.metric_deviations)  AS metric_deviations,
  (SELECT count(*) FROM app.load_deviations)     AS load_deviations;

-- Trockenlauf (Standard dieser Datei) -- verwirft alles oben, zeigt nur die Zahlen:
ROLLBACK;

-- Scharf schalten: Zeile darueber auskommentieren, diese Zeile aktivieren:
-- COMMIT;
