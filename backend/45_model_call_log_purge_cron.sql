-- =============================================================================
-- 45_model_call_log_purge_cron.sql — AP-69 Review-Fund (2026-09-29), Punkt 88:
-- automatisches Loeschen von app.model_call_log nach 1 Jahr
--
-- docs/legal/vvt.md dokumentiert die Frist bereits, ein Job dafuer fehlte.
-- Gleiches Haertungsmuster wie app.cron_baseline_engine/app.cron_loaddeviation
-- (supabase/migrations/20260927082030_wire_baseline_loaddeviation_cron.sql):
-- duenne SECURITY DEFINER Wrapper-Funktion, REVOKE/GRANT auf service_role als
-- zweite Sicherheitsebene (pg_cron laeuft in Supabase Cloud als postgres,
-- Extension-Owner -- kein alleiniger Schutz, Muster D wie im Rest des
-- Projekts), idempotentes Scheduling (erst unschedule, wenn der Job laut
-- cron.job existiert, dann neu). Taeglich 04:00, nach den bestehenden
-- Nachtlaeufen 03:00 (Baseline-Engine)/03:30 (LoadDeviation).
--
-- app.model_call_subjects haengt per call_id ON DELETE CASCADE an
-- app.model_call_log -- das DELETE hier raeumt sie automatisch mit auf, kein
-- eigenes DELETE noetig.
--
-- Voraussetzung: 20260927082030_wire_baseline_loaddeviation_cron.sql (pg_cron
-- Extension bereits installiert), 41_jev_switch_model_call_log.sql
-- (app.model_call_log). Idempotent. Tests: backend/45_model_call_log_purge_cron.pgtap.sql
-- (pg_cron selbst ist lokal nicht installiert, siehe Kopfkommentar von
-- 20260927082030_wire_baseline_loaddeviation_cron.sql -- getestet wird die
-- Wrapper-Funktion direkt, das Scheduling ist eine reine SQL-Anweisung ohne
-- pruefbares Verhalten ausserhalb von Supabase Cloud).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app.cron_purge_model_call_log — Nachtlauf 04:00
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.cron_purge_model_call_log()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
BEGIN
  DELETE FROM app.model_call_log WHERE occurred_at < now() - interval '1 year';
END;
$$;

COMMENT ON FUNCTION app.cron_purge_model_call_log() IS
  'Punkt 88 (2026-09-29), VVT-Frist (docs/legal/vvt.md): loescht app.model_call_log-Zeilen '
  'aelter als 1 Jahr, taeglich 04:00. app.model_call_subjects raeumt per ON DELETE CASCADE '
  'automatisch mit auf. Siehe backend/45_model_call_log_purge_cron.sql.';

REVOKE EXECUTE ON FUNCTION app.cron_purge_model_call_log() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.cron_purge_model_call_log() TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Cron-Job planen -- idempotent, gleiches lokal-sicheres Muster wie
--    app.cron_training_load (backend/38_training_load.sql, Abschnitt 11): erst
--    pruefen, OB pg_cron ueberhaupt verfuegbar ist (pg_available_extensions,
--    keine Exception, nur eine Katalogabfrage) -- fehlt sie (Homebrew-Postgres
--    lokal), WARNEN und ueberspringen. Ist sie verfuegbar (Supabase Cloud, dort
--    durch 20260927082030_wire_baseline_loaddeviation_cron.sql bereits
--    aktiviert), laeuft das Scheduling ungeschuetzt -- ein echter
--    Berechtigungsfehler in der Cloud bricht die Migration dann sichtbar ab.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    RAISE WARNING 'app.cron_purge_model_call_log NICHT geplant: Extension pg_cron ist auf '
      'dieser Postgres-Instanz nicht verfuegbar (pg_available_extensions). Bekannte Grenze der '
      'lokalen Test-DB (Homebrew-Postgres ohne pg_cron) -- in der Cloud darf das NICHT '
      'passieren, da 20260927082030_wire_baseline_loaddeviation_cron.sql die Extension bereits '
      'aktiviert haben muss. Siehe backend/45_model_call_log_purge_cron.sql.';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'model-call-log-purge-nightly') THEN
    PERFORM cron.unschedule('model-call-log-purge-nightly');
  END IF;

  PERFORM cron.schedule(
    'model-call-log-purge-nightly',
    '0 4 * * *',
    $cron$SELECT app.cron_purge_model_call_log();$cron$
  );
END $$;
