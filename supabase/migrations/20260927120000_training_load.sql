-- =============================================================================
-- 38_training_load.sql — Modul 6, Trainingsplanung (AP-68)
--
-- Liefert die fehlende Lastquelle fuer die Baseline-Engine: session_load und
-- acute_chronic_ratio auf app.daily_checkins sind seit 33_baseline_engine.sql
-- strukturell immer 0 Beobachtungen ("Trainingsmanagement-Modul, nicht
-- gebaut" -- siehe Kommentar dort, in dieser Migration korrigiert). SIG-03
-- "Schlaf plus Last" und SIG-04 "Lastsprung" (fachlich fertig spezifiziert,
-- nicht Teil dieses Pakets) warten auf genau diese Datenbasis.
--
-- Zuschnitt final (mit Chris abgestimmt, 2026-09-27):
--   * O-02: Session Load zaehlt auf session_date der Trainingseinheit selbst,
--     nicht auf den Folgetag.
--   * Kein app.training_session_participants (keine Teilgruppen-Zuweisung),
--     kein Status-Feld fuer Storno/Verschieben. Jede Einheit ist team-weit.
--     Planaenderungen laufen ueber Loeschen/Neuanlegen -- diese Migration
--     baut bewusst keine rpc_delete_training_session (ausserhalb DONE_WHEN
--     dieses Pakets, kein Aufrufer im Client vorbereitet).
--   * Intensitaet smallint 1-10 (konsistent zur RPE-Skala), Ziel Freitext.
--   * RPE-Erfassungsfenster wie rpc_submit_checkin: heute oder bis zu 2 Tage
--     zurueck, hier bezogen auf training_sessions.session_date.
--
-- Muster D (wie 33_baseline_engine.sql/34_readiness_score.sql/
-- 35_load_deviation.sql):
--   1. VOLATILE, app-Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny -- ausser bei genuinen
--      Eingabefehlern (RPE ausserhalb 1-10, Zeitfenster), dort RAISE mit
--      Errcode wie in 11_checkin_submit.sql (INVALID/FORBIDDEN je nach Fall).
--   3. team_id/created_by/person_id ausschliesslich aus den Auth-Helpern,
--      nie als Parameter.
--   4. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- RLS auf training_sessions/session_rpe wie bei app.daily_checkins/app.
-- load_deviations (nicht das voll-gesperrte Muster von app.baselines/app.
-- readiness_score): GRANT auf authenticated plus Policies als zweite
-- Sicherheitsebene, tatsaechlicher Schreibweg laeuft ueber die SECURITY
-- DEFINER Tueren (Function-Owner ist Superuser in der Cloud-Migration,
-- umgeht RLS wie ueberall im Projekt).
--
-- Voraussetzung: 08_reconciling.sql (auth_team_id/auth_person_id/auth_is_staff/
-- auth_has_role), 09_rpcs.sql (app.daily_checkins), 33_baseline_engine.sql
-- (app.app_metric, app.baseline_metric_config: session_load/acute_chronic_ratio
-- bereits seed, direction='neutral', hier NICHT neu angelegt). Idempotent
-- (DROP ... IF EXISTS, CREATE OR REPLACE wo der Rueckgabetyp gleich bleibt).
-- Tests: backend/38_training_load.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enum app_session_type
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  CREATE TYPE app.app_session_type AS ENUM ('field','gym','recovery','tactical','test');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 2. app.training_sessions — team-weit, kein Teilgruppen-/Status-Feld
-- -----------------------------------------------------------------------------

-- Code-Review zu Commit f7353a4 (2026-09-27), Fund 1+2:
--   * created_by war NOT NULL + ON DELETE SET NULL -- widersprach sich
--     (Loeschen der anlegenden Person haette an der NOT-NULL-Constraint
--     scheitern muessen, statt sauber auf NULL zu fallen). Jetzt nullable:
--     die Einheit bleibt bei Personen-Loeschung als Historie erhalten.
--   * duration_min hatte keine Obergrenze. session_rpe.session_load ist
--     numeric(8,3) (5 Vorkommastellen, max 99999.999) -- duration_min nahe
--     dem smallint-Maximum (32767) mit rpe=10 waere 327670, numeric field
--     overflow beim INSERT. Exakt dieselbe Overflow-Fehlerklasse wie der in
--     der Vorsession gefundene und in backend/37_load_deviation_overflow_
--     fix.sql behobene Bug bei load_deviations.deviation. 300 Minuten (5h)
--     ist grosszuegig ueber jeder realistischen Trainingseinheit oder einem
--     Ganztagslehrgang, macht aber rpe*duration_min <= 3000 (weit unter dem
--     numeric(8,3)-Limit) strukturell unmoeglich zu ueberschreiten.
CREATE TABLE IF NOT EXISTS app.training_sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id            uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  session_date       date NOT NULL,
  start_time         time,
  duration_min       smallint NOT NULL CHECK (duration_min > 0 AND duration_min <= 300),
  session_type       app.app_session_type NOT NULL DEFAULT 'field',
  planned_intensity  smallint CHECK (planned_intensity BETWEEN 1 AND 10),
  goal_text          text,
  created_by         uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS training_sessions_team_date_idx
  ON app.training_sessions (team_id, session_date DESC);

ALTER TABLE app.training_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.training_sessions FORCE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON app.training_sessions TO authenticated;

DROP POLICY IF EXISTS training_sessions_select_team ON app.training_sessions;
CREATE POLICY training_sessions_select_team ON app.training_sessions
  FOR SELECT TO authenticated
  USING (team_id = app.auth_team_id());

DROP POLICY IF EXISTS training_sessions_insert_staff ON app.training_sessions;
CREATE POLICY training_sessions_insert_staff ON app.training_sessions
  FOR INSERT TO authenticated
  WITH CHECK (team_id = app.auth_team_id() AND app.auth_is_staff());

DROP POLICY IF EXISTS training_sessions_update_staff ON app.training_sessions;
CREATE POLICY training_sessions_update_staff ON app.training_sessions
  FOR UPDATE TO authenticated
  USING (team_id = app.auth_team_id() AND app.auth_is_staff())
  WITH CHECK (team_id = app.auth_team_id() AND app.auth_is_staff());

-- Kein DELETE-Policy: das Projekt gibt Loeschen generell nicht ueber RLS frei
-- (kein FOR DELETE Policy irgendwo im Bestand, gemessen 2026-09-27), keine
-- rpc_delete_training_session in diesem Paket.

-- -----------------------------------------------------------------------------
-- 3. app.session_rpe — RPE je Spieler und Einheit, session_load generiert
-- -----------------------------------------------------------------------------
-- duration_min ist ein Snapshot aus training_sessions.duration_min zum
-- Zeitpunkt der Abgabe (bewusst kein Live-Join): eine spaetere Korrektur der
-- geplanten Dauer darf die Last eines bereits abgegebenen RPE-Eintrags nicht
-- rueckwirkend veraendern.

CREATE TABLE IF NOT EXISTS app.session_rpe (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  session_id    uuid NOT NULL REFERENCES app.training_sessions(id) ON DELETE CASCADE,
  rpe           smallint NOT NULL CHECK (rpe BETWEEN 1 AND 10),
  duration_min  smallint NOT NULL,
  session_load  numeric(8,3) GENERATED ALWAYS AS (rpe * duration_min) STORED,
  submitted_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id, session_id)
);

ALTER TABLE app.session_rpe ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.session_rpe FORCE ROW LEVEL SECURITY;

-- RPE ist kein medizinisches Feld, kein Medizin-Gate (Modul-Spec): Staff darf
-- es sehen, sobald es existiert, ohne released-Zwischenschritt.
GRANT SELECT, INSERT ON app.session_rpe TO authenticated;

DROP POLICY IF EXISTS session_rpe_select_visible ON app.session_rpe;
CREATE POLICY session_rpe_select_visible ON app.session_rpe
  FOR SELECT TO authenticated
  USING (
    team_id = app.auth_team_id()
    AND (person_id = app.auth_person_id() OR app.auth_is_staff() OR app.auth_is_medical())
  );

DROP POLICY IF EXISTS session_rpe_insert_self ON app.session_rpe;
CREATE POLICY session_rpe_insert_self ON app.session_rpe
  FOR INSERT TO authenticated
  WITH CHECK (person_id = app.auth_person_id() AND team_id = app.auth_team_id());

-- Kein eigenes UPDATE-Recht/Policy fuer authenticated: der Upsert in
-- rpc_submit_session_rpe laeuft ausschliesslich ueber die SECURITY DEFINER
-- Tuer (Function-Owner umgeht RLS und Tabellenrechte wie ueberall im Projekt).

-- -----------------------------------------------------------------------------
-- 4. app.daily_checkins um session_load/acute_chronic_ratio erweitern
-- -----------------------------------------------------------------------------
-- Beide Spalten gehoeren NICHT zum Medizin-Gate (anders als body_map/
-- pain_max): Last ist ueber load_deviations/session_load.above bereits fuer
-- Staff sichtbares Konzept (siehe backend/35_load_deviation.sql Statement-
-- Katalog). Column-Grant additiv (Postgres GRANT SELECT (cols) erweitert die
-- Freigabe, entzieht keine zuvor gewaehrten Spalten) -- die vorhandene Liste
-- aus backend/09_rpcs.sql bleibt unveraendert bestehen, hier nur ergaenzt.

ALTER TABLE app.daily_checkins
  ADD COLUMN IF NOT EXISTS session_load        numeric(8,3),
  ADD COLUMN IF NOT EXISTS acute_chronic_ratio  numeric(6,3);

GRANT SELECT (id, team_id, person_id, date, sleep_duration_min, sleep_quality,
              recovery, energy, mental_stress, mental_mood, mental_motivation,
              training_readiness, session_load, acute_chronic_ratio,
              submitted_at, created_at, updated_at)
  ON app.daily_checkins TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. app._compute_daily_session_load — Aggregation, interne Funktion
-- -----------------------------------------------------------------------------
-- Summiert session_rpe.session_load fuer person_id+date (Join ueber
-- session_id -> training_sessions.session_date = p_date, O-02: Last zaehlt
-- auf den Tag der Einheit selbst). Kein Training am Tag -> 0, nicht NULL:
-- ein Ruhetag ist echte, gezaehlte Last-Information fuer die 7/28-Tage-
-- Mittel weiter unten (app.cron_training_load), nicht "keine Beobachtung".
-- Upsert legt bei Bedarf eine daily_checkins-Zeile nur mit team_id/person_id/
-- date/session_load an (Rest NULL), analog zum Upsert in rpc_submit_checkin.

CREATE OR REPLACE FUNCTION app._compute_daily_session_load(p_person_id uuid, p_date date)
RETURNS numeric
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_load    numeric(8,3);
BEGIN
  SELECT team_id INTO v_team_id FROM app.persons WHERE id = p_person_id;

  IF v_team_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(sum(sr.session_load), 0)::numeric(8,3)
    INTO v_load
    FROM app.session_rpe sr
    JOIN app.training_sessions ts ON ts.id = sr.session_id
   WHERE sr.person_id = p_person_id
     AND ts.session_date = p_date;

  INSERT INTO app.daily_checkins (team_id, person_id, date, session_load)
  VALUES (v_team_id, p_person_id, p_date, v_load)
  ON CONFLICT (person_id, date) DO UPDATE SET
    session_load = EXCLUDED.session_load,
    updated_at   = now();

  RETURN v_load;
END;
$$;

REVOKE EXECUTE ON FUNCTION app._compute_daily_session_load(uuid, date) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. app.rpc_create_training_session — Muster D, staff-only
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_create_training_session(
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type DEFAULT 'field',
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id   uuid;
  v_person_id uuid;
  v_row       app.training_sessions%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.create', 'FORBIDDEN: training_sessions.create');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('training_sessions.create', 'FORBIDDEN: training_sessions.create');
  END IF;

  IF p_session_date IS NULL THEN
    RAISE EXCEPTION 'INVALID: training_sessions.session_date' USING errcode = '22023';
  END IF;

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NOT NULL AND p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.planned_intensity' USING errcode = '22023';
  END IF;

  v_team_id   := app.auth_team_id();
  v_person_id := app.auth_person_id();

  INSERT INTO app.training_sessions (
    team_id, session_date, start_time, duration_min, session_type,
    planned_intensity, goal_text, created_by
  )
  VALUES (
    v_team_id, p_session_date, p_start_time, p_duration_min, p_session_type,
    p_planned_intensity, p_goal_text, v_person_id
  )
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only (coach/athletic_coach). '
  'team_id/created_by ausschliesslich aus den Auth-Helpern. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. app.rpc_update_training_session — Muster D, staff-only, eigenes Team
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_update_training_session(
  p_session_id         uuid,
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type,
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_row     app.training_sessions%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  v_team_id := app.auth_team_id();

  IF NOT EXISTS (
    SELECT 1 FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id
  ) THEN
    RETURN app.deny('training_sessions.update', 'FORBIDDEN: training_sessions.update');
  END IF;

  IF p_session_date IS NULL THEN
    RAISE EXCEPTION 'INVALID: training_sessions.session_date' USING errcode = '22023';
  END IF;

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NOT NULL AND p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: training_sessions.planned_intensity' USING errcode = '22023';
  END IF;

  UPDATE app.training_sessions SET
    session_date      = p_session_date,
    start_time        = p_start_time,
    duration_min      = p_duration_min,
    session_type      = p_session_type,
    planned_intensity = p_planned_intensity,
    goal_text         = p_goal_text,
    updated_at        = now()
  WHERE id = p_session_id AND team_id = v_team_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only, nur eigenes Team. '
  'Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. app.rpc_list_training_sessions — alle Rollen, team-gescoped
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_list_training_sessions(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_rows    jsonb;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('training_sessions.list', 'FORBIDDEN: training_sessions.list');
  END IF;

  v_team_id := app.auth_team_id();

  SELECT COALESCE(jsonb_agg(to_jsonb(ts) ORDER BY ts.session_date, ts.start_time NULLS LAST), '[]'::jsonb)
    INTO v_rows
    FROM app.training_sessions ts
   WHERE ts.team_id = v_team_id
     AND (p_from IS NULL OR ts.session_date >= p_from)
     AND (p_to   IS NULL OR ts.session_date <= p_to);

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION app.rpc_list_training_sessions(date, date) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, alle Rollen, team-gescoped. '
  'Rueckgabe ist ein JSON-Array. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_list_training_sessions(date, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_list_training_sessions(date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. app.rpc_submit_session_rpe — Muster D, nur der Spieler selbst
-- -----------------------------------------------------------------------------
-- Zeitfenster wie rpc_submit_checkin: heute oder bis zu 2 Tage zurueck,
-- bezogen auf training_sessions.session_date (nicht auf den Abgabezeitpunkt).
-- duration_min wird als Snapshot aus training_sessions kopiert (Abschnitt 3).

CREATE OR REPLACE FUNCTION app.rpc_submit_session_rpe(p_session_id uuid, p_rpe smallint)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id     uuid;
  v_person_id   uuid;
  v_session     app.training_sessions%rowtype;
  v_id          uuid;
  v_daily_load  numeric;
  v_row         app.session_rpe%rowtype;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  IF NOT app.auth_has_role('player') THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  v_team_id   := app.auth_team_id();
  v_person_id := app.auth_person_id();

  SELECT * INTO v_session FROM app.training_sessions
   WHERE id = p_session_id AND team_id = v_team_id;

  IF v_session.id IS NULL THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.submit');
  END IF;

  IF v_session.session_date > current_date OR v_session.session_date < current_date - 2 THEN
    RETURN app.deny('session_rpe.submit', 'FORBIDDEN: session_rpe.window');
  END IF;

  IF p_rpe IS NULL OR p_rpe NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: session_rpe.rpe' USING errcode = '22023';
  END IF;

  INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min, submitted_at)
  VALUES (v_team_id, v_person_id, p_session_id, p_rpe, v_session.duration_min, now())
  ON CONFLICT (person_id, session_id) DO UPDATE SET
    rpe           = EXCLUDED.rpe,
    duration_min  = EXCLUDED.duration_min,
    submitted_at  = now()
  RETURNING id INTO v_id;

  v_daily_load := app._compute_daily_session_load(v_person_id, v_session.session_date);

  SELECT * INTO v_row FROM app.session_rpe WHERE id = v_id;

  RETURN to_jsonb(v_row) || jsonb_build_object('daily_session_load', v_daily_load);
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, nur der Spieler selbst. Zeitfenster wie '
  'rpc_submit_checkin (heute oder bis zu 2 Tage zurueck), bezogen auf session_date (O-02). '
  'duration_min als Snapshot aus training_sessions. Ruft im selben Aufruf app._compute_'
  'daily_session_load auf. Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_submit_session_rpe(uuid, smallint) TO authenticated;

-- -----------------------------------------------------------------------------
-- 10. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_create_training_session(
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type DEFAULT 'field',
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_create_training_session(p_session_date, p_start_time, p_duration_min, p_session_type, p_planned_intensity, p_goal_text);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_update_training_session(
  p_session_id         uuid,
  p_session_date       date,
  p_start_time         time,
  p_duration_min       smallint,
  p_session_type       app.app_session_type,
  p_planned_intensity  smallint DEFAULT NULL,
  p_goal_text          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_update_training_session(p_session_id, p_session_date, p_start_time, p_duration_min, p_session_type, p_planned_intensity, p_goal_text);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_list_training_sessions(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_list_training_sessions(p_from, p_to);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_submit_session_rpe(p_session_id uuid, p_rpe smallint)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_submit_session_rpe(p_session_id, p_rpe);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) IS 'API-Tuer fuer app.rpc_create_training_session. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) IS 'API-Tuer fuer app.rpc_update_training_session. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_list_training_sessions(date, date) IS 'API-Tuer fuer app.rpc_list_training_sessions. Invoker, nur authenticated. AP-68.';
COMMENT ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) IS 'API-Tuer fuer app.rpc_submit_session_rpe. Invoker, nur authenticated. AP-68.';

REVOKE EXECUTE ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_list_training_sessions(date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_list_training_sessions(date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_submit_session_rpe(uuid, smallint) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 11. app.cron_training_load — Nachtlauf, service_role (Cron 02:30, vor
--     app.cron_baseline_engine 03:00 und app.cron_loaddeviation 03:30 --
--     Muster wie supabase/migrations/20260927082030_wire_baseline_
--     loaddeviation_cron.sql, hier direkt im gleichen Paket verdrahtet, damit
--     der Job vom ersten Tag an existiert statt erneut vergessen zu werden.
-- -----------------------------------------------------------------------------
-- acute_chronic_ratio: acute = avg(session_load) ueber 7 Tage [as_of-6..as_of],
-- chronic = avg(session_load) ueber 28 Tage [as_of-27..as_of]. chronic = 0
-- oder NULL -> ratio NULL, kein Fehler, keine Division-durch-Null-Exception
-- (COALESCE/NULLIF-frei durch CASE, expliziter als NULLIF(chronic,0) fuer
-- die Lesbarkeit im Test).

CREATE OR REPLACE FUNCTION app.cron_training_load()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  r         record;
  v_acute   numeric;
  v_chronic numeric;
  v_ratio   numeric(6,3);
BEGIN
  FOR r IN SELECT id AS person_id FROM app.persons WHERE is_active LOOP
    PERFORM app._compute_daily_session_load(r.person_id, current_date);
  END LOOP;

  FOR r IN SELECT id AS person_id FROM app.persons WHERE is_active LOOP
    SELECT avg(dc.session_load) INTO v_acute
      FROM app.daily_checkins dc
     WHERE dc.person_id = r.person_id
       AND dc.date BETWEEN current_date - 6 AND current_date;

    SELECT avg(dc.session_load) INTO v_chronic
      FROM app.daily_checkins dc
     WHERE dc.person_id = r.person_id
       AND dc.date BETWEEN current_date - 27 AND current_date;

    v_ratio := CASE
      WHEN v_chronic IS NULL OR v_chronic = 0 THEN NULL
      ELSE round((v_acute / v_chronic)::numeric, 3)
    END;

    UPDATE app.daily_checkins
       SET acute_chronic_ratio = v_ratio, updated_at = now()
     WHERE person_id = r.person_id AND date = current_date;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION app.cron_training_load() IS
  'Nachtlauf 02:30 (AP-68, Modul 6): app._compute_daily_session_load fuer alle aktiven '
  'Personen fuer heute, danach acute_chronic_ratio (7-Tage/28-Tage-Mittel, chronic=0/NULL '
  '-> ratio NULL). Siehe backend/38_training_load.sql.';

REVOKE EXECUTE ON FUNCTION app.cron_training_load() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION app.cron_training_load() TO service_role;

-- Code-Review zu Commit f7353a4 (2026-09-27), Fund 3: ein stiller Skip ohne
-- jede Meldung wuerde exakt das Bug-Muster reproduzieren, das gerade erst
-- gefunden wurde (etwas fehlt, niemand merkt es). Deshalb hier NICHT nur
-- ein IF EXISTS-Guard: wie in 20260927082030_wire_baseline_loaddeviation_
-- cron.sql wird zuerst CREATE EXTENSION IF NOT EXISTS pg_cron versucht
-- (in der Cloud ein No-Op, die Extension existiert dort bereits). Nur wenn
-- das aus einem echten lokalen Grund scheitert (Homebrew-Postgres ohne
-- pg_cron, bekannte Grenze der lokalen Test-DB, siehe Kopfkommentar der
-- Referenzmigration), faengt die Ausnahme das ab UND meldet es laut per
-- RAISE WARNING -- der fehlende Job ist damit in jedem Migrationslauf
-- sichtbar, verschwindet aber nicht still wie zuvor. Idempotent planen:
-- erst unschedule (nur wenn der Job laut cron.job tatsaechlich existiert),
-- dann neu.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'app.cron_training_load NICHT geplant: CREATE EXTENSION pg_cron ist fehlgeschlagen (%). '
      'Bekannte Grenze der lokalen Test-DB (Homebrew-Postgres ohne pg_cron) -- in der Cloud darf das '
      'NICHT passieren, da 20260927082030_wire_baseline_loaddeviation_cron.sql die Extension bereits '
      'aktiviert haben muss. Siehe backend/38_training_load.sql.', SQLERRM;
    RETURN;
  END;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'training-load-nightly') THEN
    PERFORM cron.unschedule('training-load-nightly');
  END IF;

  PERFORM cron.schedule(
    'training-load-nightly',
    '30 2 * * *',
    $cron$SELECT app.cron_training_load();$cron$
  );
END $$;
