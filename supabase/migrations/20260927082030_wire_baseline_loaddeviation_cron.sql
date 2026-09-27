-- =============================================================================
-- 20260927082030_wire_baseline_loaddeviation_cron.sql
--
-- FUND (2026-09-27, per SQL in der Cloud verifiziert): app.metric_deviations
-- und app.load_deviations haben 0 Zeilen, obwohl app.daily_checkins 582
-- Zeilen und app.baselines 11 aktuelle Zeilen (bis 2026-09-26) hat. Ursache:
-- pg_cron ist in der Cloud-DB nicht installiert, und kein Code im Repo (Web,
-- Edge Functions, vercel.json) ruft app.rpc_compute_deviations,
-- app.rpc_recompute_baselines oder app.rpc_compute_load_deviations jemals
-- auf. Die Nachtlaeufe, die 33_baseline_engine.sql/35_load_deviation.sql
-- selbst als "Cron 03:00"/"Cron 03:30" dokumentieren, waren nie verdrahtet.
--
-- Diese Migration installiert pg_cron und plant beide Nachtlaeufe ueber zwei
-- duenne, checked-in Wrapper-Funktionen -- gleiches Prinzip wie
-- app.cron_loaddeviation, das laut Kopfkommentar von backend/35_load_
-- deviation.sql (Zeile ~23) bereits in der Cloud existiert, aber nie in
-- backend/*.sql eingecheckt war (hier reproduzierbar gemacht, wie app_metric
-- in 33_baseline_engine.sql). app.rpc_compute_deviations(person_id, date)
-- rechnet ausschliesslich pro Person (keine Team-/All-Variante) --
-- app.cron_baseline_engine() uebernimmt die Schleife ueber aktive
-- app.persons, genau wie app.rpc_recompute_baselines es fuer die Baselines
-- selbst schon tut.
--
-- Betrifft NICHT app.readiness_scores (582 Zeilen, aktuell) -- die laeuft
-- synchron ueber rpc_submit_checkin, unabhaengig von dieser Migration.
--
-- ACHTUNG (offener Punkt fuer Chris): pg_cron braucht shared_preload_
-- libraries auf Postgres-Ebene. In Supabase Cloud ist das durch die
-- Extension-Aktivierung selbst abgedeckt (dashboard oder diese Migration).
-- Lokal (Homebrew-Postgres, siehe backend/tests) ist pg_cron nicht
-- installiert -- CREATE EXTENSION pg_cron schlaegt dort fehl. Das ist eine
-- bekannte Grenze der lokalen Test-DB, kein Fehler in dieser Migration.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- pg_cron legt beim Anlegen sein eigenes Schema "cron" an (nicht ueber
-- WITH SCHEMA umlenkbar) -- kein eigenes Zielschema hier festzulegen, anders
-- als bei btree_gist in 08_reconciling.sql. Supabase Cloud unterstuetzt
-- pg_cron als Extension auf allen Plaenen.

-- -----------------------------------------------------------------------------
-- 1. app.cron_baseline_engine — Baseline-Neuberechnung + Tagesabweichung,
--    03:00. Laeuft in Supabase Cloud als postgres (Extension-Owner), nicht
--    als authenticated -- REVOKE/GRANT unten ist zweite Sicherheitsebene,
--    kein alleiniger Schutz (Muster D wie im Rest des Projekts).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.cron_baseline_engine()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM app.rpc_recompute_baselines(current_date);

  FOR r IN SELECT id AS person_id FROM app.persons WHERE is_active LOOP
    PERFORM app.rpc_compute_deviations(r.person_id, current_date);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION app.cron_baseline_engine() IS
  'Nachtlauf 03:00 (Fund 2026-09-27, siehe backend/33_baseline_engine.sql): '
  'app.rpc_recompute_baselines fuer alle aktiven Personen, danach '
  'app.rpc_compute_deviations je Person fuer denselben Tag -- rpc_compute_'
  'deviations kennt keine All-Personen-Variante. Siehe supabase/migrations/'
  '20260927082030_wire_baseline_loaddeviation_cron.sql.';

REVOKE EXECUTE ON FUNCTION app.cron_baseline_engine() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.cron_baseline_engine() TO service_role;

-- -----------------------------------------------------------------------------
-- 2. app.cron_loaddeviation — LoadDeviation-Nachtlauf, 03:30. Existierte laut
--    Kopfkommentar backend/35_load_deviation.sql bereits in der Cloud, aber
--    nie in backend/*.sql eingecheckt -- hier reproduziert (Fund-(-1)-Muster
--    wie app_metric/app.baseline_metric_config in 33_baseline_engine.sql).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.cron_loaddeviation()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
BEGIN
  PERFORM app.rpc_compute_load_deviations(current_date);
END;
$$;

COMMENT ON FUNCTION app.cron_loaddeviation() IS
  'Nachtlauf 03:30 (Fund 2026-09-27, siehe backend/35_load_deviation.sql): '
  'app.rpc_compute_load_deviations fuer den aktuellen Tag. Siehe supabase/'
  'migrations/20260927082030_wire_baseline_loaddeviation_cron.sql.';

REVOKE EXECUTE ON FUNCTION app.cron_loaddeviation() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.cron_loaddeviation() TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Cron-Jobs planen -- idempotent: erst unschedule (nur wenn der Job laut
--    cron.job tatsaechlich existiert), dann neu. Kein catch-all EXCEPTION
--    mehr (Security-Review 2026-09-27, Fund 3): ein echter Fehler beim
--    Unschedule (z.B. Berechtigung) soll die Migration abbrechen lassen,
--    statt stillschweigend einen stale/doppelten Job zu riskieren.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'baseline-engine-nightly') THEN
    PERFORM cron.unschedule('baseline-engine-nightly');
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'load-deviation-nightly') THEN
    PERFORM cron.unschedule('load-deviation-nightly');
  END IF;
END $$;

SELECT cron.schedule(
  'baseline-engine-nightly',
  '0 3 * * *',
  $$SELECT app.cron_baseline_engine();$$
);

SELECT cron.schedule(
  'load-deviation-nightly',
  '30 3 * * *',
  $$SELECT app.cron_loaddeviation();$$
);
