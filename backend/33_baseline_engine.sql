-- =============================================================================
-- 33_baseline_engine.sql — Modul 2, Baseline-Engine (Bridge Punkt 57, Teil 1 von 3)
--
-- Chris' Entscheidung (2026-09-24): bestehenden Freigabe-Workflow auf
-- app.load_deviations (rpc_release_deviation/rpc_review_deviation, AP-47a/57)
-- unangetastet lassen. Die Baseline-Engine wird daneben aufgebaut.
--
-- FUND, der diese Migration noetig macht: app.baselines, app.metric_deviations,
-- app.baseline_observations, app._compute_baseline, app.rpc_recompute_baselines,
-- app.rpc_rebuild_baseline_history, app.players_positions existierten bereits
-- in der Cloud -- fachlich vollstaendig und korrekt (Median/MAD, sigma_floor,
-- Positions-Cluster-Blend, Pause-Reset, Idempotenz), aber auf der VOR-Silo-
-- Vokabular (tenant_id/player_id, ADR-006-Aera, vor ADR-009/ADR-011). Der
-- aktuelle Auth-Hook (10_auth_hook.sql) loescht tenant_id/player_id/person_id
-- explizit aus den Claims -- app.tenant() liefert seither IMMER NULL, die
-- Engine ist seit der Silo-Umstellung tot (0 Zeilen in allen drei Tabellen).
-- app.baseline_metric_config (metric/sigma_floor/direction, alle 11 Metriken
-- seed, KEIN Tenant-Bezug) ist sauber und bleibt unveraendert bestehen.
--
-- ENTSCHEIDUNG dieser Migration: alte, leere, tote Tabellen/Funktionen DROPpen
-- und mit team_id/person_id neu aufbauen, statt ALTER-Gymnastik auf totem
-- Bestand. Kein Datenverlust moeglich (0 Zeilen ueberall, per Messung
-- 2026-09-24, siehe Session-Log). Die Rechenlogik (Median/MAD, sigma_floor,
-- Cluster-Blend, Pause-Reset, Idempotenz) wird 1:1 uebernommen, nur die
-- Vokabular-Uebersetzung und der Lesepfad aendern sich:
--   - tenant_id entfaellt (Silo, ADR-001), team_id kommt dazu.
--   - player_id -> person_id, references app.persons(id).
--   - app.players_positions entfaellt, drei Spalten wandern auf app.persons
--     (so bereits in der Modul-Spec als Zielbild vorgesehen).
--   - KEINE separate app.baseline_observations-Kopie mehr. Rohwerte kommen
--     direkt aus app.daily_checkins (9 der 11 Metriken sind dort bereits
--     Spalten mit exakt demselben Namen wie der app_metric-Enum-Wert:
--     sleep_duration_min, sleep_quality, recovery, energy, mental_stress,
--     mental_mood, mental_motivation, training_readiness, pain_max).
--     to_jsonb(dc) ->> metric::text liest die passende Spalte ohne Kopie und
--     ohne Synchronisationsrisiko (eine Quelle der Wahrheit).
--     session_load/acute_chronic_ratio (Trainingsmanagement-Modul, nicht
--     gebaut) liefern strukturell 0 Beobachtungen -> status='insufficient',
--     das ist der korrekte, sichere Default, kein Fehler.
--
-- Muster D (Modul 7 Abschnitt 6) fuer die neue Tuer:
--   1. VOLATILE, app Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny.
--   3. Kein Sachfehler moeglich (reiner Lesepfad, keine P0002-Faelle).
--   4. Kein Helper noetig, self-only (app.auth_person_id()).
--   5. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- Rueckgabeform an public.rpc_get_my_baselines: jsonb, das bei Erfolg ein
-- JSON-ARRAY ist (nicht in {members:[...]} gewrappt), damit es unveraendert
-- auf den bestehenden Client-Vertrag passt (team-performance-os-player/
-- src/lib/baselineRepo.ts: `(data ?? []) as BaselineRow[]`). Bei Ablehnung
-- liefert app.deny ein Objekt, app.is_denial erkennt es, die Tuer setzt 403 --
-- supabase-js liefert dann data=null, der Client faellt auf [] zurueck.
--
-- Voraussetzung: 09_rpcs.sql, 20_denial_answer.sql, 26_app_execute_revoke.sql,
-- 30_clearance_proposals.sql. Idempotent (DROP ... IF EXISTS, CREATE OR REPLACE
-- wo Rueckgabetyp gleich bleibt).
-- Tests: backend/33_baseline_engine.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- -1. Fund beim lokalen Testlauf: app_metric/app_direction/app_baseline_status
--     und app.baseline_metric_config existieren NUR in der Cloud, nie in
--     backend/*.sql eingecheckt (vermutlich aus der Zeit vor der Session-
--     Bridge-Disziplin). Lokale Test-DB (frisch aus backend/*.sql gebaut)
--     kennt sie nicht. Diese Migration macht sie hier zum ersten Mal
--     reproduzierbar, idempotent fuer Cloud (bereits vorhanden, No-Op) und
--     lokal (neu angelegt, identischer Stand wie in der Cloud gemessen).
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  CREATE TYPE app.app_metric AS ENUM (
    'sleep_duration_min','sleep_quality','recovery','energy',
    'mental_stress','mental_mood','mental_motivation','training_readiness',
    'pain_max','session_load','acute_chronic_ratio'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE app.app_direction AS ENUM ('higher_better','lower_better','neutral');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE app.app_baseline_status AS ENUM ('ok','insufficient','rebuilding');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS app.baseline_metric_config (
  metric      app.app_metric primary key,
  sigma_floor numeric(6,3) not null,
  direction   app.app_direction not null
);

INSERT INTO app.baseline_metric_config (metric, sigma_floor, direction) VALUES
  ('sleep_duration_min', 20.000, 'higher_better'),
  ('sleep_quality',       0.400, 'higher_better'),
  ('recovery',            0.400, 'higher_better'),
  ('energy',              0.400, 'higher_better'),
  ('mental_stress',       0.450, 'higher_better'),
  ('mental_mood',         0.450, 'higher_better'),
  ('mental_motivation',   0.450, 'higher_better'),
  ('training_readiness',  0.400, 'higher_better'),
  ('pain_max',            0.800, 'lower_better'),
  ('session_load',       60.000, 'neutral'),
  ('acute_chronic_ratio', 0.100, 'neutral')
ON CONFLICT (metric) DO NOTHING;

REVOKE ALL ON app.baseline_metric_config FROM PUBLIC, anon;
GRANT SELECT ON app.baseline_metric_config TO authenticated;

-- -----------------------------------------------------------------------------
-- 0. Tote Funktionen und Tabellen der Vor-Silo-Engine
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS app.rpc_get_my_baselines(date);
DROP FUNCTION IF EXISTS app.rpc_get_deviation_statement(uuid);
DROP FUNCTION IF EXISTS app.rpc_get_module_flag(text);
DROP FUNCTION IF EXISTS app.rpc_rebuild_baseline_history(uuid, date, date);
DROP FUNCTION IF EXISTS app.rpc_recompute_baselines(date);
DROP FUNCTION IF EXISTS app._compute_baseline(text, uuid, app.app_metric, date);
DROP FUNCTION IF EXISTS public.rpc_get_my_baselines(date);

DROP TABLE IF EXISTS app.metric_deviations;
DROP TABLE IF EXISTS app.baselines;
DROP TABLE IF EXISTS app.baseline_observations;
DROP TABLE IF EXISTS app.players_positions;

-- app.baseline_metric_config bleibt: sauber, kein Tenant-Bezug, korrekt seed.

-- -----------------------------------------------------------------------------
-- 1. Positionsfelder auf app.persons (Zielbild der Modul-Spec, Abschnitt 3)
-- -----------------------------------------------------------------------------

ALTER TABLE app.persons
  ADD COLUMN IF NOT EXISTS primary_position text,
  ADD COLUMN IF NOT EXISTS secondary_positions text[],
  ADD COLUMN IF NOT EXISTS position_cluster text;

-- -----------------------------------------------------------------------------
-- 2. baselines, neu mit team_id/person_id
-- -----------------------------------------------------------------------------

CREATE TABLE app.baselines (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references app.teams(id) on delete cascade,
  person_id     uuid not null references app.persons(id) on delete cascade,
  metric        app.app_metric not null,
  as_of         date not null,
  window_days   int  not null default 28,
  n_obs         int  not null,
  median        numeric(8,3),
  mad           numeric(8,3),
  sigma         numeric(8,3),
  p25           numeric(8,3),
  p75           numeric(8,3),
  min_val       numeric(8,3),
  max_val       numeric(8,3),
  cluster       text,
  w_self        numeric(4,3) not null default 1.000,
  direction     app.app_direction not null,
  status        app.app_baseline_status not null,
  reset_at      date,
  computed_at   timestamptz not null default now(),
  unique (person_id, metric, as_of)
);
CREATE INDEX ON app.baselines (team_id, as_of desc, metric);
CREATE INDEX ON app.baselines (person_id, metric, as_of desc);

-- -----------------------------------------------------------------------------
-- 3. metric_deviations, neu mit team_id/person_id
-- -----------------------------------------------------------------------------

CREATE TABLE app.metric_deviations (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references app.teams(id) on delete cascade,
  person_id     uuid not null references app.persons(id) on delete cascade,
  metric        app.app_metric not null,
  date          date not null,
  value         numeric(8,3) not null,
  baseline_id   uuid not null references app.baselines(id) on delete cascade,
  z             numeric(6,3) not null,
  delta_abs     numeric(8,3) not null,
  delta_pct     numeric(6,2),
  band          text not null,   -- 'normal' | 'watch' | 'marked'  (|z|<1 / 1..2 / >=2)
  computed_at   timestamptz not null default now(),
  unique (person_id, metric, date)
);
CREATE INDEX ON app.metric_deviations (team_id, date desc, band);

REVOKE ALL ON app.baselines, app.metric_deviations FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. app._compute_baseline — Median/MAD/Cluster-Blend, Rohwerte aus daily_checkins
-- -----------------------------------------------------------------------------
-- Rechenlogik 1:1 aus der toten Vorgaengerfunktion uebernommen (Median/MAD,
-- sigma_floor, Pause>14 Tage -> rebuilding, n_obs<10 -> insufficient,
-- Cluster-Blend mit team-Fallback bei <3 Peers, self-Fallback ohne Peers).
-- Neu: Rohwerte per to_jsonb(dc)->>metric::text direkt aus app.daily_checkins,
-- keine separate Beobachtungstabelle.

CREATE OR REPLACE FUNCTION app._compute_baseline(p_team_id uuid, p_person_id uuid, p_metric app.app_metric, p_as_of date)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_window      int := 28;
  v_med         numeric(8,3);
  v_mad         numeric(8,3);
  v_sigma       numeric(8,3);
  v_p25         numeric(8,3);
  v_p75         numeric(8,3);
  v_min         numeric(8,3);
  v_max         numeric(8,3);
  v_n           int;
  v_last_obs    date;
  v_sigma_floor numeric(8,3);
  v_dir         app.app_direction;
  v_w_self      numeric(4,3);
  v_cluster     text;
  v_cluster_med numeric(8,3);
  v_eff_med     numeric(8,3);
  v_bid         uuid;
BEGIN
  SELECT sigma_floor, direction INTO v_sigma_floor, v_dir
    FROM app.baseline_metric_config WHERE metric = p_metric;

  -- Fenster: [as_of - window, as_of - 1], heutiger Wert nie Teil der eigenen Baseline.
  SELECT count(*), max(dc.date)
    INTO v_n, v_last_obs
    FROM app.daily_checkins dc
   WHERE dc.person_id = p_person_id
     AND dc.date >= p_as_of - v_window AND dc.date <= p_as_of - 1
     AND (to_jsonb(dc) ->> p_metric::text) IS NOT NULL;

  v_n := COALESCE(v_n, 0);

  -- Pause: Unterbrechung > 14 Tage ohne Check-In -> Baseline verwerfen und neu aufbauen.
  IF v_last_obs IS NULL OR (p_as_of - v_last_obs) > 14 THEN
    INSERT INTO app.baselines (team_id, person_id, metric, as_of, window_days, n_obs,
                               median, mad, sigma, p25, p75, min_val, max_val,
                               cluster, w_self, direction, status, reset_at, computed_at)
    VALUES (p_team_id, p_person_id, p_metric, p_as_of, v_window, v_n,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, 1.000, v_dir, 'rebuilding', p_as_of, now())
    ON CONFLICT (person_id, metric, as_of)
    DO UPDATE SET n_obs = EXCLUDED.n_obs, status = 'rebuilding', reset_at = EXCLUDED.reset_at,
                  median = NULL, mad = NULL, sigma = NULL, p25 = NULL, p75 = NULL,
                  min_val = NULL, max_val = NULL, w_self = 1.000, computed_at = now()
    RETURNING id INTO v_bid;
    RETURN v_bid;
  END IF;

  IF v_n < 10 THEN
    INSERT INTO app.baselines (team_id, person_id, metric, as_of, window_days, n_obs,
                               median, mad, sigma, p25, p75, min_val, max_val,
                               cluster, w_self, direction, status, reset_at, computed_at)
    VALUES (p_team_id, p_person_id, p_metric, p_as_of, v_window, v_n,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, 1.000, v_dir, 'insufficient', NULL, now())
    ON CONFLICT (person_id, metric, as_of)
    DO UPDATE SET n_obs = EXCLUDED.n_obs, status = 'insufficient', reset_at = NULL,
                  median = NULL, mad = NULL, sigma = NULL, p25 = NULL, p75 = NULL,
                  min_val = NULL, max_val = NULL, w_self = 1.000, computed_at = now()
    RETURNING id INTO v_bid;
    RETURN v_bid;
  END IF;

  SELECT
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY (to_jsonb(dc) ->> p_metric::text)::numeric),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY (to_jsonb(dc) ->> p_metric::text)::numeric),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY (to_jsonb(dc) ->> p_metric::text)::numeric),
    min((to_jsonb(dc) ->> p_metric::text)::numeric),
    max((to_jsonb(dc) ->> p_metric::text)::numeric)
    INTO v_med, v_p25, v_p75, v_min, v_max
    FROM app.daily_checkins dc
   WHERE dc.person_id = p_person_id
     AND dc.date >= p_as_of - v_window AND dc.date <= p_as_of - 1
     AND (to_jsonb(dc) ->> p_metric::text) IS NOT NULL;

  v_med := round(v_med::numeric, 3);
  v_p25 := round(v_p25::numeric, 3);
  v_p75 := round(v_p75::numeric, 3);
  v_min := round(v_min::numeric, 3);
  v_max := round(v_max::numeric, 3);

  SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs((to_jsonb(dc) ->> p_metric::text)::numeric - v_med))::numeric, 3)
    INTO v_mad
    FROM app.daily_checkins dc
   WHERE dc.person_id = p_person_id
     AND dc.date >= p_as_of - v_window AND dc.date <= p_as_of - 1
     AND (to_jsonb(dc) ->> p_metric::text) IS NOT NULL;

  v_sigma := round(greatest(1.4826 * v_mad, v_sigma_floor)::numeric, 3);

  v_w_self := least(1.000, greatest(0.000, ((v_n - 5)::numeric / 15)::numeric))::numeric(4,3);

  -- Positions-Cluster (Fallback), teamintern (ADR-001, Silo).
  SELECT position_cluster INTO v_cluster FROM app.persons WHERE id = p_person_id;

  IF v_cluster IS NOT NULL THEN
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (to_jsonb(dc) ->> p_metric::text)::numeric)
      INTO v_cluster_med
      FROM app.daily_checkins dc
      JOIN app.persons pe ON pe.id = dc.person_id
     WHERE pe.team_id = p_team_id
       AND pe.position_cluster = v_cluster
       AND pe.id <> p_person_id
       AND dc.date >= p_as_of - v_window AND dc.date <= p_as_of - 1
       AND (to_jsonb(dc) ->> p_metric::text) IS NOT NULL
       AND (SELECT count(DISTINCT pe2.id) FROM app.persons pe2
             WHERE pe2.team_id = p_team_id AND pe2.position_cluster = v_cluster AND pe2.id <> p_person_id) >= 3;
  END IF;

  IF v_cluster_med IS NULL THEN
    -- Kein Cluster, oder Cluster mit weniger als 3 Peers -> Team-Baseline.
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (to_jsonb(dc) ->> p_metric::text)::numeric)
      INTO v_cluster_med
      FROM app.daily_checkins dc
      JOIN app.persons pe ON pe.id = dc.person_id
     WHERE pe.team_id = p_team_id
       AND pe.id <> p_person_id
       AND dc.date >= p_as_of - v_window AND dc.date <= p_as_of - 1
       AND (to_jsonb(dc) ->> p_metric::text) IS NOT NULL;
    v_cluster := 'team';
  END IF;

  IF v_cluster_med IS NULL THEN
    v_cluster_med := v_med;   -- keine Peers im Team -> rein persoenlich
    v_cluster := 'self';
  END IF;

  v_eff_med := round((v_w_self * v_med + (1 - v_w_self) * v_cluster_med)::numeric, 3);

  INSERT INTO app.baselines (team_id, person_id, metric, as_of, window_days, n_obs,
                             median, mad, sigma, p25, p75, min_val, max_val,
                             cluster, w_self, direction, status, reset_at, computed_at)
  VALUES (p_team_id, p_person_id, p_metric, p_as_of, v_window, v_n,
          v_eff_med, v_mad, v_sigma, v_p25, v_p75, v_min, v_max,
          v_cluster, v_w_self, v_dir, 'ok', NULL, now())
  ON CONFLICT (person_id, metric, as_of)
  DO UPDATE SET n_obs = EXCLUDED.n_obs, median = EXCLUDED.median, mad = EXCLUDED.mad,
                sigma = EXCLUDED.sigma, p25 = EXCLUDED.p25, p75 = EXCLUDED.p75,
                min_val = EXCLUDED.min_val, max_val = EXCLUDED.max_val,
                cluster = EXCLUDED.cluster, w_self = EXCLUDED.w_self,
                direction = EXCLUDED.direction, status = 'ok', reset_at = NULL,
                computed_at = now()
  RETURNING id INTO v_bid;

  RETURN v_bid;
END;
$$;

REVOKE EXECUTE ON FUNCTION app._compute_baseline(uuid, uuid, app.app_metric, date) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. app.rpc_recompute_baselines — Nachtlauf, service_role (Cron 03:00)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_recompute_baselines(p_date date)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_count int := 0;
  r record;
  m app.app_metric;
BEGIN
  FOR r IN
    SELECT p.id AS person_id, p.team_id
      FROM app.persons p
     WHERE p.is_active
  LOOP
    FOR m IN SELECT metric FROM app.baseline_metric_config LOOP
      PERFORM app._compute_baseline(r.team_id, r.person_id, m, p_date);
      v_count := v_count + 1;
    END LOOP;
  END LOOP;
  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_recompute_baselines(date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_recompute_baselines(date) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_rebuild_baseline_history — Backfill, admin only
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_rebuild_baseline_history(p_person_id uuid, p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_count   int := 0;
  v_team_id uuid;
  d         date;
  m         app.app_metric;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  IF NOT app.auth_has_role('admin') THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  SELECT team_id INTO v_team_id FROM app.persons WHERE id = p_person_id;
  IF v_team_id IS NULL OR v_team_id <> app.auth_team_id() THEN
    RETURN app.deny('baselines.rebuild', 'FORBIDDEN: baselines.rebuild');
  END IF;

  d := p_from;
  WHILE d <= p_to LOOP
    FOR m IN SELECT metric FROM app.baseline_metric_config LOOP
      PERFORM app._compute_baseline(v_team_id, p_person_id, m, d);
      v_count := v_count + 1;
    END LOOP;
    d := d + 1;
  END LOOP;

  RETURN jsonb_build_object('recomputed', v_count);
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_rebuild_baseline_history(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_rebuild_baseline_history(uuid, date, date) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. app.rpc_get_my_baselines — Muster D, self-only Lesetuer
-- -----------------------------------------------------------------------------
-- Liefert immer alle Metriken aus app.baseline_metric_config (fehlt die
-- Baseline fuer eine Metrik am angefragten Tag: on-the-fly ueber
-- _compute_baseline berechnen, damit ein Spieler ohne Nachtlauf-Historie
-- trotzdem eine Antwort bekommt -- Idempotenz macht das billig).

CREATE OR REPLACE FUNCTION app.rpc_get_my_baselines(p_as_of date DEFAULT CURRENT_DATE)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  m           app.app_metric;
  v_rows      jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('baselines.self', 'FORBIDDEN: baselines.self');
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id   := app.auth_team_id();

  FOR m IN SELECT metric FROM app.baseline_metric_config LOOP
    IF NOT EXISTS (
      SELECT 1 FROM app.baselines
       WHERE person_id = v_person_id AND metric = m AND as_of = p_as_of
    ) THEN
      PERFORM app._compute_baseline(v_team_id, v_person_id, m, p_as_of);
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'metric'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'metric',      b.metric,
               'median',      b.median,
               'p25',         b.p25,
               'p75',         b.p75,
               'sigma',       b.sigma,
               'sigma_floor', c.sigma_floor,
               'direction',   b.direction,
               'status',      b.status,
               'n_obs',       b.n_obs,
               'w_self',      b.w_self,
               'cluster',     b.cluster,
               'raw_series',  (
                 SELECT COALESCE(jsonb_agg(jsonb_build_object('d', dc.date, 'v', (to_jsonb(dc) ->> b.metric::text)::numeric) ORDER BY dc.date), '[]'::jsonb)
                   FROM app.daily_checkins dc
                  WHERE dc.person_id = v_person_id
                    AND dc.date >= p_as_of - b.window_days AND dc.date <= p_as_of - 1
                    AND (to_jsonb(dc) ->> b.metric::text) IS NOT NULL
               )
             ) AS x
        FROM app.baselines b
        JOIN app.baseline_metric_config c ON c.metric = b.metric
       WHERE b.person_id = v_person_id AND b.as_of = p_as_of
    ) s;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_get_my_baselines(date) IS
  'Baseline-Engine (2026-09-24, Bridge Punkt 57): Tuer public.rpc_get_my_baselines. '
  'Muster D, Ablehnung als Antwort. Erfolg liefert ein JSON-Array (nicht gewrappt), '
  'passend zum bestehenden Client-Vertrag in team-performance-os-player/src/lib/'
  'baselineRepo.ts. Rechnet fehlende Baselines on-the-fly nach (idempotent), '
  'damit auch ohne Nachtlauf-Historie eine Antwort kommt. Siehe backend/33_baseline_engine.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_my_baselines(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_my_baselines(date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. Die Tuer in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_get_my_baselines(p_as_of date DEFAULT CURRENT_DATE)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_my_baselines(p_as_of);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_get_my_baselines(date) IS
  'API-Tuer fuer app.rpc_get_my_baselines. Invoker, nur authenticated. Bridge Punkt 57.';

REVOKE EXECUTE ON FUNCTION public.rpc_get_my_baselines(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_get_my_baselines(date) TO authenticated, service_role;
