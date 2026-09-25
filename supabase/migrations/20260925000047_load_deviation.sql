-- =============================================================================
-- 35_load_deviation.sql — Modul 5, LoadDeviation (Bridge Punkt 57, Teil 3 von 3)
--
-- KOLLISION, gemessen und mit Chris geklaert (2026-09-25): app.load_deviations
-- + app.rpc_release_deviation (Tuer public.rpc_review_deviation, AP-47a/57) ist
-- KEIN eigenes Konzept neben der Modul-Spec, sondern derselbe Gegenstand,
-- an drei verschiedenen Baustellen:
--
--   Teil A -- solide, aktuell, aber nirgends verdrahtet: app.load_deviations
--   (team_id/person_id/date/deviation/state) und app.rpc_release_deviation +
--   Tuer public.rpc_review_deviation. Korrektes Silo-Vokabular, physio/doctor
--   Gate, P0002->404 (Punkt 64), schreibt access_log (Befund A3). 0 Zeilen,
--   kein Aufrufer -- bleibt in dieser Migration UNVERAENDERT, wird nur an die
--   erweiterte Tabelle angeschlossen (siehe Abschnitt 1).
--
--   Teil B -- tote Vor-Silo-Reste, exakt das Baseline-Engine-Muster: app.
--   rpc_get_deviations_today, app.rpc_compute_load_deviations, app.
--   rpc_set_module_flag referenzierten tenant_id/player_id/metric/
--   deviation_pct/detected_on -- keine dieser Spalten existiert auf den echten
--   Tabellen. app.tenant() liest den Claim tenant_id, den der Auth-Hook
--   loescht -> immer NULL. Alle drei waeren bei jedem Aufruf abgestuerzt.
--   app.module_flags (tenant_id text statt team_id uuid) haengt an derselben
--   toten Vokabular-Generation. app.cron_loaddeviation ruft nur
--   rpc_compute_load_deviations auf und wird durch dessen Fix automatisch
--   mitkorrigiert, bleibt unangetastet.
--
--   Teil C -- komplett fehlend, aber vom Player-Client schon erwartet: app.
--   rpc_get_person_deviations, app.rpc_get_deviation_statement, app.
--   rpc_get_module_flag existierten gar nicht. team-performance-os-player/
--   src/lib/deviationRepo.ts ruft alle drei bereits auf (Tab "Abweichungen",
--   LoadDeviationScreen.tsx), aber mit einem Vertrag, der zu keiner echten
--   Struktur passt: tenant_id/player_id statt team_id/person_id, und ein
--   AppMetric-Typ (resting_hr/hrv_rmssd/sleep_duration/sleep_efficiency/
--   subjective_readiness), der zu keinem Wert im echten app_metric-Enum
--   passt. Gleiches Muster wie beim Readiness-Score: Client wird in
--   derselben Session auf die Spec umgestellt (deviationRepo.ts).
--
-- ZWEI ZUSAETZLICHE FUNDE, unabhaengig von der Kollision:
--   (1) app.load_deviations hatte keine metric-Spalte -- nur eine Zahl je
--       Person und Tag. Die Spec braucht eine Zeile PRO METRIK und Tag
--       (Abschnitt 1 unten).
--   (2) RLS-Luecke (bisher harmlos, 0 Zeilen): load_deviations_select_team
--       liess JEDES Teammitglied JEDEN Zustand lesen -- die Regel "Coach
--       sieht nur state=released, nie pain_max" (ADR-007) war nicht
--       erzwungen (Abschnitt 2 unten).
--
-- SCOPE dieser Migration: Backend vollstaendig nach Modul-LoadDeviation.md
-- Abschnitt 3-5 (Tabelle, module_flags, statement_catalog, alle sechs RPCs),
-- Player-Client-Fix (deviationRepo.ts, bestehender Screen, keine neue UI).
-- BEWUSST NICHT GEBAUT: eine neue Web-Oberflaeche fuer die Freigabe
-- (rpc_review_deviation bleibt ueber die API erreichbar, ohne Trigger im
-- Web -- neue Interaktion braucht den Design-Codex, nicht Teil des DONE_WHEN
-- dieses Pakets). DisclaimerBar/DeviationList/DeviationBadge im Web (Modul-
-- Spec Abschnitt 6) ebenso nicht, da es dafuer noch keine Seite gibt.
--
-- Muster D (wie 33_baseline_engine.sql/34_readiness_score.sql):
--   1. VOLATILE, app-Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny -- ausser bei Funktionen mit
--      Rueckgabetyp text/boolean, die kein jsonb tragen koennen (rpc_get_
--      deviation_statement, rpc_get_module_flag): dort RAISE mit P0002 fuer
--      "nicht sichtbar" (dieselbe Antwort wie rpc_release_deviation) bzw.
--      stiller false-Rueckfall ohne Team.
--   3. MODULE_DISABLED ist keine Rechtefrage (ADR-007 Abschnitt 3), sondern
--      eine Produktentscheidung des Arztes -- RAISE, kein log_denial.
--   4. Team- und Zustandspruefung der Zielperson vor jedem Protokoll-INSERT.
--   5. Erste Bedingung: app.auth_team_id() IS NULL -> deny/false/P0002.
--
-- Voraussetzung: 09_rpcs.sql (app.load_deviations, RLS-Grundgeruest),
-- 31_medical_doors.sql (app.rpc_release_deviation), 33_baseline_engine.sql
-- (app.metric_deviations, app.app_metric). Idempotent (DROP ... IF EXISTS,
-- CREATE OR REPLACE wo der Rueckgabetyp gleich bleibt).
-- Tests: backend/35_load_deviation.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Tote Vor-Silo-Funktionen
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS app.rpc_get_deviations_today(date);
DROP FUNCTION IF EXISTS app.rpc_set_module_flag(text, boolean);
DROP FUNCTION IF EXISTS app.rpc_get_deviation_statement(uuid);
DROP FUNCTION IF EXISTS app.rpc_get_module_flag(text);
DROP FUNCTION IF EXISTS app.module_enabled(text);
DROP FUNCTION IF EXISTS public.rpc_get_deviations_today(date);
DROP FUNCTION IF EXISTS public.rpc_get_module_flag(text);
DROP FUNCTION IF EXISTS public.rpc_set_module_flag(text, boolean);
DROP FUNCTION IF EXISTS public.rpc_get_deviation_statement(uuid);
DROP FUNCTION IF EXISTS public.rpc_get_person_deviations(uuid, date, date);

DROP TABLE IF EXISTS app.module_flags;

-- -----------------------------------------------------------------------------
-- 1. app.load_deviations um metric und Persistenz-Kennzahlen erweitern
-- -----------------------------------------------------------------------------
-- Fund (1): die Tabelle trug bisher nur eine Zahl je Person und Tag, die Spec
-- (Abschnitt 2/3) braucht eine Zeile PRO METRIK und Tag. app.rpc_release_
-- deviation/public.rpc_review_deviation bleiben unangetastet -- sie kennen die
-- vier neuen Spalten nicht und muessen sie auch nicht kennen.

ALTER TABLE app.load_deviations
  ADD COLUMN IF NOT EXISTS metric        app.app_metric,
  ADD COLUMN IF NOT EXISTS streak_days   integer,
  ADD COLUMN IF NOT EXISTS days_out_7    integer,
  ADD COLUMN IF NOT EXISTS z_mean_7      numeric(6,3),
  ADD COLUMN IF NOT EXISTS trend_slope_7 numeric(8,4),
  ADD COLUMN IF NOT EXISTS magnitude     numeric(10,4),
  ADD COLUMN IF NOT EXISTS statement_key text;

-- 0 Zeilen (gemessen 2026-09-25) -> NOT NULL direkt setzbar, kein Backfill.
ALTER TABLE app.load_deviations ALTER COLUMN metric SET NOT NULL;

ALTER TABLE app.load_deviations DROP CONSTRAINT IF EXISTS load_deviations_person_id_date_key;
ALTER TABLE app.load_deviations ADD CONSTRAINT load_deviations_person_metric_date_key
  UNIQUE (person_id, metric, date);

CREATE INDEX IF NOT EXISTS idx_load_deviations_team_date ON app.load_deviations (team_id, date DESC, metric);

-- -----------------------------------------------------------------------------
-- 2. RLS-Luecke schliessen (Fund 2)
-- -----------------------------------------------------------------------------
-- load_deviations_select_team liess bisher jedes Teammitglied jeden Zustand
-- lesen. Ersetzt durch zwei Policies, die die Absicht des Kommentars in
-- 09_rpcs.sql ("alle in Team sehen released, nur medical+self sehen
-- unreviewed") tatsaechlich durchsetzen, plus das Medizin-Gate auf pain_max
-- (Modul-Spec Abschnitt 2: "Koerperlich pain_max fuer Staff sichtbar: nein" --
-- unabhaengig vom state). load_deviations_select_self und
-- load_deviations_update_medical bleiben unveraendert, sie waren schon korrekt.
--
-- In der Praxis laeuft der API-Zugriff ausschliesslich ueber die SECURITY
-- DEFINER Tueren unten (Muster D, wie im Rest des Projekts) -- Schema app ist
-- fuer PostgREST nicht exponiert (PGRST106, gemessen in der Gegenlesung mit
-- Opus). Diese Policies sind zweite Sicherheitsebene, nicht der einzige Schutz.

DROP POLICY IF EXISTS load_deviations_select_team ON app.load_deviations;

CREATE POLICY load_deviations_select_staff ON app.load_deviations
  FOR SELECT TO authenticated
  USING (
    team_id = app.auth_team_id()
    AND app.auth_is_staff()
    AND state = 'released'
    AND metric <> 'pain_max'
  );

CREATE POLICY load_deviations_select_medical ON app.load_deviations
  FOR SELECT TO authenticated
  USING (
    team_id = app.auth_team_id()
    AND app.auth_is_medical()
  );

-- -----------------------------------------------------------------------------
-- 3. app.module_flags, neu mit team_id (Teil B)
-- -----------------------------------------------------------------------------

CREATE TABLE app.module_flags (
  team_id     uuid not null references app.teams(id) on delete cascade,
  flag        text not null,
  enabled     boolean not null default false,
  set_by      uuid references app.persons(id),
  set_by_role app.app_role,
  set_at      timestamptz not null default now(),
  primary key (team_id, flag)
);

-- Kein direkter Tabellenzugriff: ohne RLS auf einer team-gescopten Tabelle
-- waere jede GRANT SELECT ein Cross-Team-Leck (ADR-001). Zugriff nur ueber
-- app.module_enabled/rpc_get_module_flag/rpc_set_module_flag (Muster D).
REVOKE ALL ON app.module_flags FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. app.statement_catalog reproduzierbar machen (Fund -1 wie bei app_metric
--    in 33_baseline_engine.sql: existierte nur in der Cloud, nie in
--    backend/*.sql eingecheckt). Die 6 bestehenden Zeilen sind Wort fuer Wort
--    aus Modul-LoadDeviation.md Abschnitt 3 -- unveraendert, keine Korrektur.
--    Ergaenzt um die restlichen 12 Schluessel fuer die anderen 6 der 9
--    LoadDeviation-Metriken (Abschnitt 2 der Spec), gleicher Stil.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app.statement_catalog (
  key      text primary key,
  template text not null
);

REVOKE ALL ON app.statement_catalog FROM PUBLIC, anon;
GRANT SELECT ON app.statement_catalog TO authenticated;

INSERT INTO app.statement_catalog (key, template) VALUES
  ('sleep_duration_min.above',  'Schlafdauer {delta_abs} Minuten ueber der eigenen Norm'),
  ('sleep_duration_min.below',  'Schlafdauer {delta_abs} Minuten unter der eigenen Norm'),
  ('sleep_quality.above',       'Schlafqualitaet {delta_abs} Punkte ueber der eigenen Norm'),
  ('sleep_quality.below',       'Schlafqualitaet {delta_abs} Punkte unter der eigenen Norm'),
  ('recovery.above',            'Erholung {delta_abs} Punkte ueber der eigenen Norm'),
  ('recovery.below',            'Erholung {delta_abs} Punkte unter der eigenen Norm'),
  ('mental_stress.above',       'Mentale Anspannung {delta_abs} Punkte ueber der eigenen Norm'),
  ('mental_stress.below',       'Mentale Anspannung {delta_abs} Punkte unter der eigenen Norm'),
  ('mental_mood.above',         'Stimmung {delta_abs} Punkte ueber der eigenen Norm'),
  ('mental_mood.below',         'Stimmung {delta_abs} Punkte unter der eigenen Norm'),
  ('mental_motivation.above',   'Motivation {delta_abs} Punkte ueber der eigenen Norm'),
  ('mental_motivation.below',   'Motivation {delta_abs} Punkte unter der eigenen Norm'),
  ('pain_max.above',            'Schmerzangabe {delta_abs} Punkte ueber der eigenen Norm'),
  ('pain_max.below',            'Schmerzangabe {delta_abs} Punkte unter der eigenen Norm'),
  ('session_load.above',        'Trainingsbelastung {delta_pct} Prozent ueber dem eigenen 4 Wochen Schnitt'),
  ('session_load.below',        'Trainingsbelastung {delta_pct} Prozent unter dem eigenen 4 Wochen Schnitt'),
  ('acute_chronic_ratio.above', 'Wochenlast {delta_pct} Prozent ueber dem eigenen 4 Wochen Schnitt'),
  ('acute_chronic_ratio.below', 'Wochenlast {delta_pct} Prozent unter dem eigenen 4 Wochen Schnitt')
ON CONFLICT (key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5. app.module_enabled — Helper, team-gescoped statt tenant-gescoped
-- -----------------------------------------------------------------------------

CREATE FUNCTION app.module_enabled(p_flag text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT COALESCE(
    (SELECT enabled FROM app.module_flags WHERE team_id = app.auth_team_id() AND flag = p_flag),
    false
  );
$$;

REVOKE EXECUTE ON FUNCTION app.module_enabled(text) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_compute_load_deviations — Nachtlauf, service_role (Cron 03:30)
-- -----------------------------------------------------------------------------
-- Liest app.metric_deviations (Baseline-Engine, team_id/person_id/metric/date/
-- z/delta_pct), beschraenkt auf die 9 Metriken aus der Modul-Spec Abschnitt 2
-- (energy/training_readiness gehoeren zu Readiness-Score, nicht zu
-- LoadDeviation). Persistenzkennzahlen (Abschnitt 2 der Spec) werden hier
-- berechnet, nicht in metric_deviations gespeichert -- Baseline-Engine bleibt
-- unangetastet. ON CONFLICT laesst state/reviewed_by/reviewed_at/released_at
-- unberuehrt: ein Nachtlauf darf eine bereits gesichtete Zeile nicht auf
-- unreviewed zuruecksetzen.

CREATE OR REPLACE FUNCTION app.rpc_compute_load_deviations(p_date date DEFAULT CURRENT_DATE)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_count  integer := 0;
  r        record;
  v_streak integer;
  v_cursor date;
  v_z      numeric;
BEGIN
  FOR r IN
    SELECT
      md.team_id, md.person_id, md.metric, md.delta_pct,
      (
        SELECT count(*) FROM app.metric_deviations d7
         WHERE d7.person_id = md.person_id AND d7.metric = md.metric
           AND d7.date BETWEEN p_date - 6 AND p_date AND abs(d7.z) >= 1
      ) AS days_out_7,
      (
        SELECT avg(d7.z) FROM app.metric_deviations d7
         WHERE d7.person_id = md.person_id AND d7.metric = md.metric
           AND d7.date BETWEEN p_date - 6 AND p_date
      ) AS z_mean_7,
      (
        SELECT regr_slope(d7.z, d7.date - p_date) FROM app.metric_deviations d7
         WHERE d7.person_id = md.person_id AND d7.metric = md.metric
           AND d7.date BETWEEN p_date - 6 AND p_date
      ) AS trend_slope_7
    FROM app.metric_deviations md
   WHERE md.date = p_date
     AND abs(md.z) >= 1
     AND md.metric IN (
       'sleep_duration_min', 'sleep_quality', 'recovery',
       'mental_stress', 'mental_mood', 'mental_motivation',
       'pain_max', 'session_load', 'acute_chronic_ratio'
     )
  LOOP
    -- streak_days: aufeinanderfolgende Tage bis einschliesslich p_date mit |z| >= 1.
    v_streak := 0;
    v_cursor := p_date;
    LOOP
      SELECT z INTO v_z FROM app.metric_deviations
       WHERE person_id = r.person_id AND metric = r.metric AND date = v_cursor;
      EXIT WHEN v_z IS NULL OR abs(v_z) < 1;
      v_streak := v_streak + 1;
      v_cursor := v_cursor - 1;
    END LOOP;

    INSERT INTO app.load_deviations (
      team_id, person_id, metric, date, deviation, state,
      streak_days, days_out_7, z_mean_7, trend_slope_7, magnitude, statement_key
    )
    VALUES (
      r.team_id, r.person_id, r.metric, p_date, COALESCE(r.delta_pct, 0), 'unreviewed',
      v_streak, r.days_out_7, round(r.z_mean_7::numeric, 3), round(r.trend_slope_7::numeric, 4),
      round((abs(COALESCE(r.z_mean_7, 0)) * COALESCE(r.days_out_7, 0))::numeric, 4),
      r.metric::text || (CASE WHEN COALESCE(r.delta_pct, 0) >= 0 THEN '.above' ELSE '.below' END)
    )
    ON CONFLICT (person_id, metric, date) DO UPDATE
      SET deviation     = EXCLUDED.deviation,
          streak_days   = EXCLUDED.streak_days,
          days_out_7    = EXCLUDED.days_out_7,
          z_mean_7      = EXCLUDED.z_mean_7,
          trend_slope_7 = EXCLUDED.trend_slope_7,
          magnitude     = EXCLUDED.magnitude,
          statement_key = EXCLUDED.statement_key;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_compute_load_deviations(date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.rpc_compute_load_deviations(date) TO service_role;

-- app.cron_loaddeviation ruft nur app.rpc_compute_load_deviations(current_date)
-- auf, keine eigenen Spaltenverweise -- durch den Fix oben automatisch
-- mitkorrigiert, kein Aendern noetig.

-- -----------------------------------------------------------------------------
-- 7. app.rpc_get_module_flag / app.rpc_set_module_flag — Muster D
-- -----------------------------------------------------------------------------

CREATE FUNCTION app.rpc_get_module_flag(p_flag text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN false;
  END IF;
  RETURN app.module_enabled(p_flag);
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_get_module_flag(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_module_flag(text) TO authenticated;

CREATE FUNCTION app.rpc_set_module_flag(p_flag text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_row app.module_flags;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('module_flags.set', 'FORBIDDEN: module_flags.set');
  END IF;

  -- Modul-Spec Abschnitt 4: ausschliesslich doctor, nicht admin.
  IF NOT app.auth_has_role('doctor') THEN
    RETURN app.deny('module_flags.set', 'FORBIDDEN: module_flags.set (only doctor)');
  END IF;

  INSERT INTO app.module_flags (team_id, flag, enabled, set_by, set_by_role, set_at)
  VALUES (app.auth_team_id(), p_flag, p_enabled, app.auth_person_id(), 'doctor'::app.app_role, now())
  ON CONFLICT (team_id, flag) DO UPDATE
    SET enabled = EXCLUDED.enabled, set_by = EXCLUDED.set_by,
        set_by_role = EXCLUDED.set_by_role, set_at = EXCLUDED.set_at
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'flag', v_row.flag, 'enabled', v_row.enabled,
    'set_by', v_row.set_by, 'set_at', v_row.set_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_set_module_flag(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_set_module_flag(text, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. app.rpc_get_person_deviations — self, staff (gefiltert), medical
-- -----------------------------------------------------------------------------
-- "Staff (gefiltert)" heisst: state='released' und nie pain_max, gleiche Regel
-- wie die RLS-Policy oben, hier explizit im Rumpf (die Funktion laeuft als
-- Definer und umgeht RLS, wie jede Tuer in diesem Projekt).

CREATE FUNCTION app.rpc_get_person_deviations(
  p_person_id uuid,
  p_from      date DEFAULT NULL,
  p_to        date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_is_self    boolean;
  v_is_medical boolean;
  v_rows       jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('load_deviations.get', 'FORBIDDEN: load_deviations.get');
  END IF;

  IF NOT app.module_enabled('loaddeviation_enabled') THEN
    RAISE EXCEPTION 'MODULE_DISABLED' USING errcode = '55000';
  END IF;

  v_is_self    := (app.auth_person_id() = p_person_id);
  v_is_medical := app.auth_is_medical();

  IF NOT (v_is_self OR v_is_medical OR app.auth_is_staff()) THEN
    RETURN app.deny('load_deviations.get', 'FORBIDDEN: load_deviations.get');
  END IF;

  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('load_deviations.get', 'FORBIDDEN: load_deviations.get');
  END IF;

  IF NOT v_is_self THEN
    INSERT INTO app.access_log (team_id, subject_id, actor_id, actor_role, resource, action, scope_date)
    VALUES (
      app.auth_team_id(), p_person_id, app.auth_person_id(), app.denial_actor_role(),
      'load_deviations', 'read', COALESCE(p_from, current_date)
    );
  END IF;

  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'detected_on' DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'id',            ld.id,
               'person_id',     ld.person_id,
               'metric',        ld.metric,
               'deviation_pct', ld.deviation,
               'detected_on',   ld.date,
               'state',         ld.state,
               'streak_days',   ld.streak_days,
               'days_out_7',    ld.days_out_7,
               'z_mean_7',      ld.z_mean_7,
               'trend_slope_7', ld.trend_slope_7,
               'magnitude',     ld.magnitude,
               'statement_key', ld.statement_key,
               'reviewed_by',   ld.reviewed_by,
               'reviewed_at',   ld.reviewed_at,
               'released_at',   ld.released_at,
               'created_at',    ld.created_at
             ) AS x
        FROM app.load_deviations ld
       WHERE ld.team_id   = app.auth_team_id()
         AND ld.person_id = p_person_id
         AND (v_is_self OR v_is_medical OR (ld.state = 'released' AND ld.metric <> 'pain_max'))
         AND (p_from IS NULL OR ld.date >= p_from)
         AND (p_to   IS NULL OR ld.date <= p_to)
    ) s;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_get_person_deviations(uuid, date, date) IS
  'LoadDeviation (Modul 5, Bridge Punkt 57 Teil 3). Tuer public.rpc_get_person_deviations. '
  'Muster D. Rueckgabe-Feldnamen (deviation_pct, detected_on) bewusst wie im bestehenden '
  'Player-Client (deviationRepo.ts), obwohl die Spaltennamen intern deviation/date heissen -- '
  'LoadDeviationScreen.tsx bleibt dadurch unveraendert. Staff gefiltert: nur state=released, '
  'nie pain_max. Siehe backend/35_load_deviation.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_person_deviations(uuid, date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_person_deviations(uuid, date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. app.rpc_get_deviation_statement — text, P0002 statt jsonb-Ablehnung
-- -----------------------------------------------------------------------------
-- Rueckgabetyp text kann kein Ablehnungsobjekt tragen (derselbe Grund wie bei
-- rpc_get_my_baselines' Umstieg auf jsonb, hier aber von der Spec als text
-- vorgegeben). Fremdes Team, unbekannte Id und ein fuer die Rolle unsichtbarer
-- Zustand (Staff auf unreviewed/dismissed oder pain_max) geben dieselbe
-- Antwort -- dasselbe Prinzip wie rpc_release_deviation bei P0002.
-- Kein eigener access_log-Eintrag: die Sichtbarkeit wurde bereits beim Lesen
-- der Liste (rpc_get_person_deviations) protokolliert, der Text ist derselbe
-- bereits freigegebene Datensatz, keine zweite Ressource.

CREATE FUNCTION app.rpc_get_deviation_statement(p_deviation_id uuid)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_ld        app.load_deviations;
  v_delta_abs numeric;
  v_delta_pct numeric;
  v_tmpl      text;
  v_is_self   boolean;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: load_deviations' USING errcode = 'P0002';
  END IF;

  IF NOT app.module_enabled('loaddeviation_enabled') THEN
    RAISE EXCEPTION 'MODULE_DISABLED' USING errcode = '55000';
  END IF;

  SELECT * INTO v_ld FROM app.load_deviations
   WHERE id = p_deviation_id AND team_id = app.auth_team_id();

  IF v_ld.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: load_deviations' USING errcode = 'P0002';
  END IF;

  v_is_self := (app.auth_person_id() = v_ld.person_id);

  IF NOT (
    v_is_self
    OR app.auth_is_medical()
    OR (app.auth_is_staff() AND v_ld.state = 'released' AND v_ld.metric <> 'pain_max')
  ) THEN
    RAISE EXCEPTION 'NOT_FOUND: load_deviations' USING errcode = 'P0002';
  END IF;

  SELECT delta_abs, delta_pct INTO v_delta_abs, v_delta_pct
    FROM app.metric_deviations
   WHERE person_id = v_ld.person_id AND metric = v_ld.metric AND date = v_ld.date;

  SELECT template INTO v_tmpl FROM app.statement_catalog WHERE key = v_ld.statement_key;

  IF v_tmpl IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN replace(
           replace(v_tmpl, '{delta_abs}', to_char(abs(COALESCE(v_delta_abs, 0)), 'FM999990.0')),
           '{delta_pct}', to_char(abs(COALESCE(v_delta_pct, 0)), 'FM999990.0')
         );
END;
$$;

COMMENT ON FUNCTION app.rpc_get_deviation_statement(uuid) IS
  'LoadDeviation (Modul 5, Bridge Punkt 57 Teil 3). Tuer public.rpc_get_deviation_statement. '
  'text statt jsonb (Spec-Vorgabe): Ablehnung als P0002/404, dieselbe Antwort fuer fremdes '
  'Team, unbekannte Id und rollenbedingt unsichtbaren Zustand. Siehe backend/35_load_deviation.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_deviation_statement(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_deviation_statement(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 10. app.rpc_get_deviations_today — Staff-/Medizin-Tagesuebersicht, Team
-- -----------------------------------------------------------------------------
-- Rueckgabetyp jsonb statt SETOF/TABLE (derselbe Grund wie rpc_get_my_
-- baselines: ein Ablehnungsobjekt passt in kein TABLE). Team-weite Liste wie
-- rpc_list_team_members/rpc_morning_ops: bewusst KEIN access_log-Eintrag,
-- gleiche Begruendung wie dort (eine Uebersicht ist kein Oeffnen einer
-- einzelnen Person). Aktuell ohne Web-Aufrufer (Modul-Spec Abschnitt 5,
-- kein DONE_WHEN dieses Pakets fuer eine neue Seite) -- Backend vollstaendig,
-- Verdrahtung ist ein eigenes, kuenftiges Paket.

CREATE FUNCTION app.rpc_get_deviations_today(p_date date DEFAULT CURRENT_DATE)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, auth, pg_temp
AS $$
DECLARE
  v_is_medical boolean;
  v_rows       jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('load_deviations.today', 'FORBIDDEN: load_deviations.today');
  END IF;

  IF NOT app.module_enabled('loaddeviation_enabled') THEN
    RAISE EXCEPTION 'MODULE_DISABLED' USING errcode = '55000';
  END IF;

  v_is_medical := app.auth_is_medical();

  IF NOT (v_is_medical OR app.auth_is_staff()) THEN
    RETURN app.deny('load_deviations.today', 'FORBIDDEN: load_deviations.today');
  END IF;

  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'person_id'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'person_id',  ld.person_id,
               'deviations', jsonb_agg(
                 jsonb_build_object(
                   'id',            ld.id,
                   'metric',        ld.metric,
                   'deviation_pct', ld.deviation,
                   'state',         ld.state,
                   'magnitude',     ld.magnitude,
                   'streak_days',   ld.streak_days,
                   'days_out_7',    ld.days_out_7,
                   'statement_key', ld.statement_key
                 ) ORDER BY ld.magnitude DESC NULLS LAST
               )
             ) AS x
        FROM app.load_deviations ld
       WHERE ld.team_id = app.auth_team_id()
         AND ld.date    = p_date
         AND (v_is_medical OR (ld.state = 'released' AND ld.metric <> 'pain_max'))
       GROUP BY ld.person_id
    ) s;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_get_deviations_today(date) IS
  'LoadDeviation (Modul 5, Bridge Punkt 57 Teil 3). Tuer public.rpc_get_deviations_today. '
  'Muster D, Ablehnung als Antwort. Team-weite Liste, kein access_log (wie rpc_list_team_'
  'members/rpc_morning_ops). Staff gefiltert: nur state=released, nie pain_max. '
  'Siehe backend/35_load_deviation.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_deviations_today(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_deviations_today(date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 11. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_get_person_deviations(p_person_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_person_deviations(p_person_id, p_from, p_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_get_deviation_statement(p_deviation_id uuid)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  RETURN app.rpc_get_deviation_statement(p_deviation_id);
EXCEPTION WHEN no_data_found THEN
  PERFORM set_config('response.status', '404', true);
  RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_get_deviations_today(p_date date DEFAULT CURRENT_DATE)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_deviations_today(p_date);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_get_module_flag(p_flag text)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  RETURN app.rpc_get_module_flag(p_flag);
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_set_module_flag(p_flag text, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_set_module_flag(p_flag, p_enabled);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_get_person_deviations(uuid, date, date) IS 'API-Tuer fuer app.rpc_get_person_deviations. Invoker, nur authenticated. Bridge Punkt 57.';
COMMENT ON FUNCTION public.rpc_get_deviation_statement(uuid)           IS 'API-Tuer fuer app.rpc_get_deviation_statement. Invoker, nur authenticated. Bridge Punkt 57.';
COMMENT ON FUNCTION public.rpc_get_deviations_today(date)              IS 'API-Tuer fuer app.rpc_get_deviations_today. Invoker, nur authenticated. Bridge Punkt 57.';
COMMENT ON FUNCTION public.rpc_get_module_flag(text)                   IS 'API-Tuer fuer app.rpc_get_module_flag. Invoker, nur authenticated. Bridge Punkt 57.';
COMMENT ON FUNCTION public.rpc_set_module_flag(text, boolean)          IS 'API-Tuer fuer app.rpc_set_module_flag. Invoker, nur authenticated. Bridge Punkt 57.';

REVOKE EXECUTE ON FUNCTION public.rpc_get_person_deviations(uuid, date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_get_deviation_statement(uuid)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_get_deviations_today(date)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_get_module_flag(text)                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_set_module_flag(text, boolean)          FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_get_person_deviations(uuid, date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_deviation_statement(uuid)           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_deviations_today(date)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_module_flag(text)                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_set_module_flag(text, boolean)          TO authenticated, service_role;
