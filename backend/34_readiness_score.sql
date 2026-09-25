-- =============================================================================
-- 34_readiness_score.sql — Modul 4, Readiness Score (Bridge Punkt 57, Teil 2 von 3)
--
-- FUND, der diese Migration noetig macht (2026-09-25, vor dem Bauen gemessen):
-- app.compute_readiness, app.readiness_score (singular), app.readiness_factor_medical
-- existierten bereits in der Cloud, aber auf der VOR-Silo-Vokabular (tenant_id
-- text/player_id uuid, ADR-006-Aera, wie die Baseline-Engine letzte Session).
-- Lesen aus app.daily_checkin/app.daily_checkin_medical (Singular, beide 0 Zeilen,
-- ebenfalls tot), kein Trigger haengt an compute_readiness -- unerreichbar. Alle
-- drei Tabellen 0 Zeilen (gemessen 2026-09-25). ENTSCHEIDUNG: droppen und mit
-- team_id/person_id neu aufbauen, exakt das Muster aus 33_baseline_engine.sql.
-- app.recompute_value_sport/app.recompute_value_full waren nur von compute_readiness
-- aufgerufen, gehen mit.
--
-- ZWEITER FUND (needs_decision, mit Chris am 2026-09-25 geklärt): der Player-Client
-- (team-performance-os-player/src/lib/scoreRepo.ts, live in ScoreScreen.tsx und
-- DashboardScreen.tsx) rief bereits rpc_get_my_scores(p_days) mit einem Vertrag
-- auf, der zur toten Vor-Silo-Funktion passte (sum_sleep/sum_muscle/regions_n --
-- rohe Checkin-Summen, kein Baseline-Bezug), NICHT zur Modul-Spec v2.0 (5-Faktor
-- Median/MAD-z-Modell, physical aus pain_max/training_readiness statt Muskel/
-- Body-Map). Chris' Entscheidung: Spec korrekt bauen, Client mitziehen (siehe
-- scoreRepo.ts/ScoreScreen.tsx in derselben Session angepasst).
--
-- Vokabular-Uebersetzung (Modul-Spec nennt weiterhin players/player_id, KEIN
-- team_id -- Live-Schema gewinnt, wie bei der Baseline-Engine):
--   - players/player_id -> app.persons/person_id.
--   - team_id kommt dazu (Silo-Konvention, wie bei allen anderen app.*-Tabellen).
--   - Sichtbarkeit: die Spec beschreibt RLS-Policies (`create policy ... using`).
--     Dieses Projekt nutzt fuer Artikel-9-Tabellen durchgaengig NICHT RLS-Policies,
--     sondern REVOKE ALL FROM authenticated + ausschliesslich SECURITY DEFINER
--     Tueren (Muster D, siehe 33_baseline_engine.sql Abschnitt 3 Kommentar). Genau
--     dieses Muster wird hier fortgesetzt: kein CREATE POLICY, stattdessen REVOKE
--     ALL und zwei self-only Tueren. "Strukturell 0 Zeilen fuer coach" bedeutet in
--     diesem Projekt: authenticated hat ueberhaupt kein SELECT-Recht auf die
--     Tabelle (has_table_privilege = false), nicht eine RLS-Policy-Auswertung.
--
-- Rechenkern: z je Metrik aus app.baselines (Median/MAD, siehe Baseline-Engine),
-- direction-korrigiert (lower_better invertiert, z.B. pain_max), zu Faktor-z
-- gewichtet gemittelt (Gewicht = readiness_weights.weight_full, renormiert auf
-- die tatsaechlich verfuegbaren Metriken je Faktor), dann Punkte 0..100 zentriert
-- auf 50 (load bidirektional: 50 - 12.5*|z|, alle anderen 50 + 12.5*z -- das ist
-- der v2.0-KRITISCHE-FIX aus der Spec, NICHT die fehlerhafte v1.0-Variante).
-- value_full/value_sport = gewichteter Schnitt der verfuegbaren Faktor-Punkte,
-- Gewicht = Faktor-Gesamtgewicht (weight_full bzw. weight_sport), automatisch
-- renormiert auf die verfuegbaren Faktoren (Gewichte fehlender Faktoren fallen
-- aus Zaehler UND Nenner -- kein Sonderfall noetig). completeness = Anteil des
-- verfuegbaren Gewichts an 1.000 (weight_full-Basis, gilt fuer beide Varianten).
--
-- load (session_load/acute_chronic_ratio) ist strukturell IMMER 'insufficient'
-- (Trainingsmanagement-Modul nicht gebaut, 0 Beobachtungen) -- das ist laut Spec-
-- Randfall-Tabelle der korrekte, sichere Default (Gewicht faellt auf die uebrigen
-- vier Faktoren um), kein Fehler dieser Migration.
--
-- context_factors wird angelegt und beim Score-Aufbau gelesen (LEFT JOIN), aber
-- in diesem Paket von niemandem beschrieben -- context_flags ist deshalb bis auf
-- Weiteres immer '{}'. Das Beschreiben (Spielplan/Reise-Import) ist nicht Teil
-- dieses Pakets.
--
-- Muster D (wie 33_baseline_engine.sql):
--   1. VOLATILE, app-Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny.
--   3. Kein Sachfehler moeglich (reiner Lesepfad mit on-the-fly Compute).
--   4. Kein Helper noetig, self-only (app.auth_person_id()).
--   5. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- Scope dieser Migration (Bridge Punkt 57 Teil 2, siehe Contract): nur
-- rpc_get_my_score(p_date) und rpc_get_my_scores(p_days), beide self-only.
-- rpc_get_score_detail/rpc_team_scores/rpc_compute_score/rpc_recompute_scores/
-- rpc_explain_score (Phase 4, Cron, Erklaertexte) sind NICHT Teil dieses Pakets.
--
-- Voraussetzung: 33_baseline_engine.sql (app.baselines, app._compute_baseline,
-- app.baseline_metric_config). Idempotent (DROP ... IF EXISTS, CREATE OR REPLACE
-- wo der Rueckgabetyp gleich bleibt).
-- Tests: backend/34_readiness_score.pgtap.sql.
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE app.app_score_status AS ENUM ('ok','insufficient','no_baseline');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 0. Tote Vor-Silo-Funktionen und -Tabellen
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS app.compute_readiness(uuid);
DROP FUNCTION IF EXISTS app.recompute_value_sport(jsonb);
DROP FUNCTION IF EXISTS app.recompute_value_full(jsonb, jsonb);

DROP TABLE IF EXISTS app.readiness_factor_medical;
DROP TABLE IF EXISTS app.readiness_score;

-- -----------------------------------------------------------------------------
-- 1. readiness_weights — Config-Tabelle, Gewichte NICHT hartkodiert
-- -----------------------------------------------------------------------------
-- weight_full/weight_sport sind bereits die END-Gewichte je Metrik (Faktor-Gewicht
-- mal Metrik-Anteil im Faktor, z.B. sleep_duration_min: 0.25 * 0.6 = 0.15). Summe
-- je Variante ueber alle Zeilen = 1.000 (siehe pgTAP). Die Faktor-interne
-- Renormierung (bei fehlender Einzelmetrik) und die Faktor-Renormierung (bei
-- fehlendem ganzen Faktor) leiten sich daraus ab, keine zweite Gewichtsspalte
-- noetig (siehe app._compute_readiness_score).

CREATE TABLE IF NOT EXISTS app.readiness_weights (
  algo_version  text not null,
  factor        text not null,
  metric        app.app_metric not null,
  weight_full   numeric(6,5) not null,
  weight_sport  numeric(6,5) not null,
  is_medical    boolean not null default false,
  primary key (algo_version, factor, metric)
);

INSERT INTO app.readiness_weights (algo_version, factor, metric, weight_full, weight_sport, is_medical) VALUES
  ('v1', 'sleep',    'sleep_duration_min',  0.15000, 0.18750, false),
  ('v1', 'sleep',    'sleep_quality',       0.10000, 0.12500, false),
  ('v1', 'recovery', 'recovery',            0.12500, 0.15625, false),
  ('v1', 'recovery', 'energy',              0.12500, 0.15625, false),
  ('v1', 'mental',   'mental_stress',       0.05000, 0.06250, false),
  ('v1', 'mental',   'mental_mood',         0.05000, 0.06250, false),
  ('v1', 'mental',   'mental_motivation',   0.05000, 0.06250, false),
  ('v1', 'load',     'acute_chronic_ratio', 0.07500, 0.09375, false),
  ('v1', 'load',     'session_load',        0.07500, 0.09375, false),
  ('v1', 'physical', 'pain_max',            0.14000, 0.00000, true),
  ('v1', 'physical', 'training_readiness',  0.06000, 0.00000, true)
ON CONFLICT (algo_version, factor, metric) DO NOTHING;

REVOKE ALL ON app.readiness_weights FROM PUBLIC, anon;
GRANT SELECT ON app.readiness_weights TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. context_factors — deskriptiver Kontext, GENAU EIN Team im Silo (ADR-011)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.context_factors (
  id                 uuid primary key default gen_random_uuid(),
  date               date not null,
  match_density_7d   int  not null default 0,
  travel_hours_48h   numeric(5,2) not null default 0,
  timezone_shift_h   int  not null default 0,
  note               text,
  unique (date)
);

REVOKE ALL ON app.context_factors FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. readiness_score — Coach-sichtbar, NUR value_sport (kein value_full hier)
-- -----------------------------------------------------------------------------

CREATE TABLE app.readiness_score (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references app.teams(id) on delete cascade,
  person_id     uuid not null references app.persons(id) on delete cascade,
  date          date not null,
  value_sport   int  check (value_sport between 0 and 100),
  completeness  numeric(4,3) not null,
  status        app.app_score_status not null,
  context_flags text[] not null default '{}',
  algo_version  text not null,
  computed_at   timestamptz not null default now(),
  unique (person_id, date)
);
CREATE INDEX ON app.readiness_score (team_id, date desc);
CREATE INDEX ON app.readiness_score (person_id, date desc);

-- -----------------------------------------------------------------------------
-- 4. readiness_factors_coach — 4 nichtmedizinische Faktoren, weight = gewicht_sport
-- -----------------------------------------------------------------------------

CREATE TABLE app.readiness_factors_coach (
  id            uuid primary key default gen_random_uuid(),
  score_id      uuid not null references app.readiness_score(id) on delete cascade,
  team_id       uuid not null references app.teams(id) on delete cascade,
  person_id     uuid not null references app.persons(id) on delete cascade,
  date          date not null,
  factor        text not null,
  weight        numeric(6,5) not null,
  factor_z      numeric(6,3),
  points        numeric(6,2),
  contribution  numeric(6,2),
  unique (score_id, factor)
);
CREATE INDEX ON app.readiness_factors_coach (person_id, date desc);

-- -----------------------------------------------------------------------------
-- 5. readiness_factor_medical — value_full + physical, PHYSISCH getrennt
--    (ADR-009 §2 Invariante: nie aus value_sport ableitbar, eigene Tabelle)
-- -----------------------------------------------------------------------------

CREATE TABLE app.readiness_factor_medical (
  id            uuid primary key default gen_random_uuid(),
  score_id      uuid not null references app.readiness_score(id) on delete cascade,
  team_id       uuid not null references app.teams(id) on delete cascade,
  person_id     uuid not null references app.persons(id) on delete cascade,
  date          date not null,
  value_full    int  check (value_full between 0 and 100),
  factor        text not null,
  weight        numeric(6,5) not null,
  factor_z      numeric(6,3),
  points        numeric(6,2),
  contribution  numeric(6,2),
  detail        jsonb,
  unique (score_id, factor)
);
CREATE INDEX ON app.readiness_factor_medical (person_id, date desc);

-- Kein direkter Tabellenzugriff fuer authenticated auf alle drei Score-Tabellen --
-- Zugriff ausschliesslich ueber die beiden SECURITY DEFINER Tueren unten (Muster D,
-- wie bei app.baselines/app.metric_deviations). Das ist der strukturelle Beweis,
-- den pgTAP unten prueft (has_table_privilege = false), nicht eine Rollenpruefung
-- im Code.
REVOKE ALL ON app.readiness_score, app.readiness_factors_coach, app.readiness_factor_medical
  FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. app._compute_readiness_score — Rechenkern, self-Aufruf on-the-fly
-- -----------------------------------------------------------------------------
-- Stellt zuerst sicher, dass fuer alle 11 Metriken eine Baseline zum Zieldatum
-- existiert (app._compute_baseline, idempotent, wie rpc_get_my_baselines). Liest
-- dann Rohwert + Baseline je Metrik, korrigiert die Richtung (lower_better
-- invertiert), aggregiert gewichtet zu Faktor-z, rechnet Punkte (load bidirektional,
-- v2.0-Fix), summiert renormiert zu value_full/value_sport, schreibt Score plus
-- Faktor-Zeilen (nur fuer tatsaechlich berechenbare Faktoren, unabhaengig vom
-- Gesamtstatus -- maximale Transparenz statt alles-oder-nichts).

CREATE OR REPLACE FUNCTION app._compute_readiness_score(p_team_id uuid, p_person_id uuid, p_date date)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_algo         text := 'v1';
  v_score_id     uuid;
  v_value_full   int;
  v_value_sport  int;
  v_completeness numeric(4,3);
  v_status       app.app_score_status;
  v_context      text[];
  m              app.app_metric;
BEGIN
  -- Baseline je Metrik sicherstellen (idempotent, wie rpc_get_my_baselines).
  FOR m IN SELECT metric FROM app.baseline_metric_config LOOP
    IF NOT EXISTS (
      SELECT 1 FROM app.baselines WHERE person_id = p_person_id AND metric = m AND as_of = p_date
    ) THEN
      PERFORM app._compute_baseline(p_team_id, p_person_id, m, p_date);
    END IF;
  END LOOP;

  CREATE TEMP TABLE IF NOT EXISTS _rs_metric (
    factor text, metric app.app_metric, weight_full numeric(6,5), weight_sport numeric(6,5),
    is_medical boolean, z numeric(6,3)
  ) ON COMMIT DROP;
  DELETE FROM _rs_metric;

  INSERT INTO _rs_metric (factor, metric, weight_full, weight_sport, is_medical, z)
  SELECT
    w.factor, w.metric, w.weight_full, w.weight_sport, w.is_medical,
    CASE
      WHEN b.status IS DISTINCT FROM 'ok' OR v_raw.value IS NULL THEN NULL
      WHEN cfg.direction = 'lower_better'
        THEN -round((v_raw.value - b.median) / greatest(b.sigma, cfg.sigma_floor), 3)
      ELSE round((v_raw.value - b.median) / greatest(b.sigma, cfg.sigma_floor), 3)
    END AS z
  FROM app.readiness_weights w
  JOIN app.baseline_metric_config cfg ON cfg.metric = w.metric
  LEFT JOIN app.baselines b
    ON b.person_id = p_person_id AND b.metric = w.metric AND b.as_of = p_date
  LEFT JOIN LATERAL (
    SELECT (to_jsonb(dc) ->> w.metric::text)::numeric AS value
      FROM app.daily_checkins dc
     WHERE dc.person_id = p_person_id AND dc.date = p_date
  ) v_raw ON true
  WHERE w.algo_version = v_algo;

  CREATE TEMP TABLE IF NOT EXISTS _rs_factor (
    factor text, weight_full numeric(6,5), weight_sport numeric(6,5), is_medical boolean,
    factor_z numeric(6,3), points numeric(6,2)
  ) ON COMMIT DROP;
  DELETE FROM _rs_factor;

  -- Zweistufige Aggregation: erst je Metrik (Tabelle _rs_metric, oben befuellt),
  -- dann zu Faktor-Gewicht/Faktor-z verdichtet (weight_full/weight_sport hier sind
  -- FAKTOR-Summen, nicht mehr Metrik-Gewichte).
  INSERT INTO _rs_factor (factor, weight_full, weight_sport, is_medical, factor_z, points)
  SELECT
    agg.factor,
    agg.factor_weight_full,
    agg.factor_weight_sport,
    agg.is_medical,
    agg.fz,
    CASE
      WHEN agg.fz IS NULL THEN NULL
      WHEN agg.factor = 'load' THEN least(100, greatest(0, round(50 - 12.5 * abs(agg.fz), 2)))
      ELSE least(100, greatest(0, round(50 + 12.5 * agg.fz, 2)))
    END
  FROM (
    SELECT
      factor,
      sum(weight_full)                                                        AS factor_weight_full,
      sum(weight_sport)                                                       AS factor_weight_sport,
      bool_or(is_medical)                                                     AS is_medical,
      (sum(weight_full * z) FILTER (WHERE z IS NOT NULL))
        / nullif(sum(weight_full) FILTER (WHERE z IS NOT NULL), 0)            AS fz
    FROM _rs_metric
    GROUP BY factor
  ) agg;

  SELECT
    round(sum(weight_full * points) FILTER (WHERE points IS NOT NULL)
          / nullif(sum(weight_full) FILTER (WHERE points IS NOT NULL), 0))::int,
    round(sum(weight_sport * points) FILTER (WHERE points IS NOT NULL)
          / nullif(sum(weight_sport) FILTER (WHERE points IS NOT NULL), 0))::int,
    round(sum(weight_full) FILTER (WHERE points IS NOT NULL)::numeric, 3)
  INTO v_value_full, v_value_sport, v_completeness
  FROM _rs_factor;

  v_completeness := coalesce(v_completeness, 0.000);

  v_status := CASE
    WHEN v_completeness = 0 THEN 'no_baseline'
    WHEN v_completeness < 0.6 THEN 'insufficient'
    ELSE 'ok'
  END;

  IF v_status <> 'ok' THEN
    v_value_full  := NULL;
    v_value_sport := NULL;
  END IF;

  SELECT coalesce(array_agg(flag), '{}') INTO v_context
    FROM (
      SELECT unnest(ARRAY[]::text[]) AS flag
       WHERE EXISTS (SELECT 1 FROM app.context_factors WHERE date = p_date)
    ) f;

  INSERT INTO app.readiness_score (team_id, person_id, date, value_sport, completeness, status, context_flags, algo_version, computed_at)
  VALUES (p_team_id, p_person_id, p_date, v_value_sport, v_completeness, v_status, coalesce(v_context, '{}'), v_algo, now())
  ON CONFLICT (person_id, date) DO UPDATE SET
    value_sport = EXCLUDED.value_sport, completeness = EXCLUDED.completeness,
    status = EXCLUDED.status, context_flags = EXCLUDED.context_flags,
    algo_version = EXCLUDED.algo_version, computed_at = now()
  RETURNING id INTO v_score_id;

  DELETE FROM app.readiness_factors_coach WHERE score_id = v_score_id;
  DELETE FROM app.readiness_factor_medical WHERE score_id = v_score_id;

  -- Alle Faktor-Zeilen werden geschrieben, auch wenn points NULL ist (Faktor
  -- strukturell nicht berechenbar, z.B. load fast immer). Das macht "kein Wert"
  -- von "Zeile fehlt" unterscheidbar und ist die einzige Stelle, an der der
  -- Gesamt-value_full persistiert -- sonst waere er unauffindbar, sobald genau
  -- der physical-Faktor selbst fehlt, obwohl die anderen Faktoren fuer ein
  -- 'ok' gereicht haben.
  INSERT INTO app.readiness_factors_coach (score_id, team_id, person_id, date, factor, weight, factor_z, points, contribution)
  SELECT v_score_id, p_team_id, p_person_id, p_date, factor, weight_sport, factor_z, points,
         round(weight_sport * points, 2)
    FROM _rs_factor
   WHERE NOT is_medical;

  INSERT INTO app.readiness_factor_medical (score_id, team_id, person_id, date, value_full, factor, weight, factor_z, points, contribution, detail)
  SELECT v_score_id, p_team_id, p_person_id, p_date, v_value_full, factor, weight_full, factor_z, points,
         round(weight_full * points, 2),
         jsonb_build_object('metric_count', (SELECT count(*) FROM _rs_metric mm WHERE mm.factor = _rs_factor.factor AND mm.z IS NOT NULL))
    FROM _rs_factor
   WHERE is_medical;

  RETURN v_score_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION app._compute_readiness_score(uuid, uuid, date) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 7. app.rpc_get_my_score — Muster D, self-only, ein Tag im Detail
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_get_my_score(p_date date DEFAULT CURRENT_DATE)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  v_score_id  uuid;
  v_row       app.readiness_score%rowtype;
  v_factors   jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('readiness_scores.self', 'FORBIDDEN: readiness_scores.self');
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id   := app.auth_team_id();

  -- Heute wird immer neu gerechnet (Nachtrag am selben Tag moeglich, rpc_submit_checkin
  -- erlaubt ON CONFLICT DO UPDATE), vergangene Tage sind eingefroren (Reproduzierbarkeit).
  IF p_date = current_date OR NOT EXISTS (
    SELECT 1 FROM app.readiness_score WHERE person_id = v_person_id AND date = p_date
  ) THEN
    v_score_id := app._compute_readiness_score(v_team_id, v_person_id, p_date);
  END IF;

  SELECT * INTO v_row FROM app.readiness_score WHERE person_id = v_person_id AND date = p_date;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_factors
    FROM (
      SELECT jsonb_build_object('factor', factor, 'weight', weight, 'factor_z', factor_z,
                                 'points', points, 'contribution', contribution, 'medical', false) AS x
        FROM app.readiness_factors_coach WHERE score_id = v_row.id
      UNION ALL
      SELECT jsonb_build_object('factor', factor, 'weight', weight, 'factor_z', factor_z,
                                 'points', points, 'contribution', contribution, 'medical', true, 'detail', detail) AS x
        FROM app.readiness_factor_medical WHERE score_id = v_row.id
    ) s;

  RETURN jsonb_build_object(
    'date',          v_row.date,
    'value_full',    (SELECT value_full FROM app.readiness_factor_medical WHERE score_id = v_row.id LIMIT 1),
    'value_sport',   v_row.value_sport,
    'completeness',  v_row.completeness,
    'status',        v_row.status,
    'context_flags', v_row.context_flags,
    'algo_version',  v_row.algo_version,
    'factors_self',  v_factors
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_get_my_score(date) IS
  'Readiness-Score (Modul 4, Bridge Punkt 57 Teil 2). Muster D, self-only, on-the-fly '
  'Compute. value_full nur vorhanden wenn status=ok. Siehe backend/34_readiness_score.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_my_score(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_my_score(date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. app.rpc_get_my_scores — Muster D, self-only, N Tage fuer den Player-Client
-- -----------------------------------------------------------------------------
-- Rueckgabeform passt auf den (in dieser Session korrigierten) Client-Vertrag
-- team-performance-os-player/src/lib/scoreRepo.ts: JSON-ARRAY (nicht gewrappt),
-- neueste zuerst, je Tag { date, value_full, value_sport, completeness, status,
-- factors: {sleep, recovery, mental, load, physical} } -- factors ist die fuer
-- self zusammengefuehrte Punkte-Sicht aus beiden Tabellen (self darf ohnehin
-- beide lesen, siehe Sichtbarkeitstabelle Modul-Spec Abschnitt 4).

CREATE OR REPLACE FUNCTION app.rpc_get_my_scores(p_days int DEFAULT 14)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id uuid;
  v_team_id   uuid;
  d           date;
  v_today     date := current_date;
  v_rows      jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('readiness_scores.self', 'FORBIDDEN: readiness_scores.self');
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id   := app.auth_team_id();

  -- Heute wird immer neu gerechnet (siehe rpc_get_my_score), vergangene Tage
  -- sind eingefroren und werden nur beim ersten Fehlen berechnet.
  d := v_today - greatest(p_days, 1) + 1;
  WHILE d <= v_today LOOP
    IF d = v_today OR NOT EXISTS (
      SELECT 1 FROM app.readiness_score WHERE person_id = v_person_id AND date = d
    ) THEN
      PERFORM app._compute_readiness_score(v_team_id, v_person_id, d);
    END IF;
    d := d + 1;
  END LOOP;

  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'date' DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'date',         rs.date,
               'value_full',   fm.value_full,
               'value_sport',  rs.value_sport,
               'completeness', rs.completeness,
               'status',       rs.status,
               'factors',      (
                 SELECT jsonb_object_agg(factor, points)
                   FROM (
                     SELECT factor, points FROM app.readiness_factors_coach WHERE score_id = rs.id
                     UNION ALL
                     SELECT factor, points FROM app.readiness_factor_medical WHERE score_id = rs.id
                   ) p
               )
             ) AS x
        FROM app.readiness_score rs
        LEFT JOIN LATERAL (
          SELECT value_full FROM app.readiness_factor_medical WHERE score_id = rs.id LIMIT 1
        ) fm ON true
       WHERE rs.person_id = v_person_id
         AND rs.date >= v_today - greatest(p_days, 1) + 1 AND rs.date <= v_today
    ) s;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_get_my_scores(int) IS
  'Readiness-Score Verlauf fuer den Player-Client (rpc_get_my_scores). Muster D, '
  'self-only. Rueckgabe ist ein JSON-Array, passend zu scoreRepo.ts. '
  'Siehe backend/34_readiness_score.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_my_scores(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_my_scores(int) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_get_my_score(p_date date DEFAULT CURRENT_DATE)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_my_score(p_date);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_get_my_score(date) IS
  'API-Tuer fuer app.rpc_get_my_score. Invoker, nur authenticated. Bridge Punkt 57.';

REVOKE EXECUTE ON FUNCTION public.rpc_get_my_score(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_get_my_score(date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpc_get_my_scores(p_days int DEFAULT 14)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_my_scores(p_days);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_get_my_scores(int) IS
  'API-Tuer fuer app.rpc_get_my_scores. Invoker, nur authenticated. Bridge Punkt 57.';

REVOKE EXECUTE ON FUNCTION public.rpc_get_my_scores(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_get_my_scores(int) TO authenticated, service_role;
