-- =============================================================================
-- 43_hint_dismissal_fixes.sql — AP-69 Review-Fund (2026-09-29), Punkt 85:
-- zwei Wegklick-Randfaelle
--
-- Fund 1: app.rpc_update_training_session loescht seit dem Review vom
-- 2026-09-27 (backend/40_squad_check.sql Abschnitt 5b) die Wegklicks EINER
-- Einheit, wenn sich DEREN Datum/Dauer/Intensitaet aendert. h2 ("geplante
-- Tageslast z >= +1") haengt aber von ALLEN Einheiten desselben Tages ab
-- (app._squad_check_v1 summiert ueber app.training_sessions.session_date).
-- Wird eine ANDERE Einheit desselben Tages angelegt oder geaendert, aendert
-- sich die Tageslast fuer JEDE Einheit dieses Tages -- ein bereits
-- weggeklickter h2-Hinweis einer NICHT bearbeiteten Einheit blieb bisher
-- trotzdem weggeklickt, obwohl die Eskalationsbedingung sich veraendert haben
-- kann. Fix: app.rpc_create_training_session und app.rpc_update_training_session
-- loeschen zusaetzlich alle h2-Wegklicks ANDERER Einheiten desselben Teams am
-- betroffenen Tag (bei Update: altes UND neues Datum, falls verschieden).
-- Nur h2 ist betroffen -- h1 (Band) und h4 (freigegebene Abweichungen) haengen
-- nicht von anderen Einheiten desselben Tages ab.
--
-- Fund 2: h1 und h4 werden in app._squad_check_v1 gegen den "heutigen" Stand
-- berechnet (Band: app.readiness_scores.date = current_date; h4-Fenster:
-- current_date - 6 .. current_date) -- NIE gegen das Einheitsdatum, das ist so
-- gewollt (ein Check-in fuer eine Einheit naechste Woche existiert noch
-- nicht). Ein Wegklick von h1/h4 ist aber nur an (session_id, person_id,
-- hint_key, rule_version) gebunden, nicht an den Tag, an dem weggeklickt
-- wurde. Klickt ein Trainer h1 fuer eine Einheit naechste Woche HEUTE weg
-- (weil das Band HEUTE "low" ist), bleibt der Wegklick stehen, auch wenn sich
-- das Band an JEDEM folgenden Tag bis zur Einheit selbst veraendert -- der
-- Trainer sieht den (moeglicherweise ganz anders begruendeten) Hinweis nie
-- wieder, obwohl er inhaltlich mit dem urspruenglich weggeklickten nichts mehr
-- zu tun hat. Analog zum bereits geloesten Fund "app._squad_check_clearance
-- prüfte nur current_date, nicht das Einheitsdatum" (40_squad_check.sql,
-- Security-Review M1): auch hier zaehlt fuer tagesaktuelle Hinweise nur der
-- TAG, an dem tatsaechlich ausgewertet wird. Fix: app._squad_check_v1
-- beruecksichtigt einen h1/h4-Wegklick nur noch, wenn er AM SELBEN Kalendertag
-- erfolgte, an dem die Pruefung laeuft (dismissed_at::date = current_date).
-- Ein aelterer h1/h4-Wegklick zaehlt weder fuer die Eskalation noch erscheint
-- er noch in dismissed_hints -- er ist inhaltlich ueberholt. h2 bleibt davon
-- unberuehrt (dort greift der Fund-1-Fix: der Wegklick wird explizit
-- geloescht statt still zu verblassen, weil h2 an einen konkreten Tagesplan
-- gebunden ist, der sich nachvollziehbar aendert). j1 (JEV-Hinweis, kein Teil
-- von _squad_check_v1) ist von beiden Funden nicht betroffen.
--
-- Beide Funktionen Rumpf 1:1 aus backend/40_squad_check.sql (Abschnitte 2, 5b)
-- uebernommen, CREATE OR REPLACE, Signatur/Rueckgabetyp/ACL unveraendert.
-- Voraussetzung: 40_squad_check.sql, 38_training_load.sql. Idempotent.
-- Tests: backend/43_hint_dismissal_fixes.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app._squad_check_v1 — h1/h4-Wegklicks nur am selben Kalendertag gueltig
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._squad_check_v1(
  p_team_id            uuid,
  p_date               date,
  p_duration_min       smallint,
  p_planned_intensity  smallint,
  p_session_id         uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_ld_on        boolean;
  v_plan         numeric;
  v_sigma_floor  numeric;
  v_result       jsonb;
BEGIN
  IF p_team_id IS NULL OR p_date IS NULL OR p_duration_min IS NULL OR p_planned_intensity IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  v_ld_on := COALESCE(
    (SELECT mf.enabled FROM app.module_flags mf
      WHERE mf.team_id = p_team_id AND mf.flag = 'loaddeviation_enabled'),
    false);

  v_plan := (p_planned_intensity::numeric * p_duration_min::numeric)
          + COALESCE((
              SELECT sum(ts.planned_intensity::numeric * ts.duration_min::numeric)
                FROM app.training_sessions ts
               WHERE ts.team_id = p_team_id
                 AND ts.session_date = p_date
                 AND ts.planned_intensity IS NOT NULL
                 AND (p_session_id IS NULL OR ts.id <> p_session_id)
            ), 0);

  SELECT c.sigma_floor INTO v_sigma_floor
    FROM app.baseline_metric_config c WHERE c.metric = 'session_load';

  WITH players AS (
    SELECT pe.id AS person_id
      FROM app.persons pe
     WHERE pe.team_id = p_team_id
       AND pe.is_active
       AND EXISTS (
         SELECT 1 FROM app.role_assignments ra
          WHERE ra.person_id = pe.id AND ra.team_id = pe.team_id AND ra.role = 'player'
            AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())
       )
  ),
  base AS (
    SELECT
      p.person_id,
      -- Freigabe: strengerer Status aus heute UND dem Datum der Einheit
      -- (Security-Review M1), siehe app._squad_check_clearance.
      app._squad_check_clearance(p_team_id, p.person_id, p_date) AS clearance,
      -- Nur das Band, nie score_total/factors.
      (SELECT rs.band FROM app.readiness_scores rs
        WHERE rs.person_id = p.person_id AND rs.team_id = p_team_id
          AND rs.date = current_date) AS band,
      -- Check-in ja/nein wie hasCheckIn in app.rpc_morning_ops.
      EXISTS (
        SELECT 1 FROM app.daily_checkins dc
         WHERE dc.person_id = p.person_id AND dc.team_id = p_team_id
           AND dc.date = current_date AND dc.checkin_submitted_at IS NOT NULL
      ) AS has_checkin,
      bl.median AS bl_median,
      bl.sigma  AS bl_sigma,
      CASE WHEN v_ld_on THEN COALESCE((
        SELECT jsonb_agg(DISTINCT ld.statement_key ORDER BY ld.statement_key)
          FROM app.load_deviations ld
         WHERE ld.person_id = p.person_id AND ld.team_id = p_team_id
           AND ld.state = 'released'
           AND ld.metric <> 'pain_max'
           AND ld.statement_key IS NOT NULL
           AND ld.date BETWEEN current_date - 6 AND current_date
      ), '[]'::jsonb) ELSE '[]'::jsonb END AS dev_keys,
      -- Punkt 85 Fund 2 (Review 2026-09-29): h1/h4 sind tagesaktuell (Band/
      -- Abweichungsfenster gelten fuer HEUTE, nie fuer das Einheitsdatum). Ein
      -- h1/h4-Wegklick zaehlt deshalb nur, wenn er AM SELBEN Kalendertag
      -- erfolgte, an dem hier ausgewertet wird -- sonst bezieht er sich auf
      -- einen laengst ueberholten Tagesstand. h2 (Tageslast) und j1
      -- (JEV-Hinweis, hier ohnehin nicht Teil der Regel) bleiben unbefristet:
      -- h2 wird stattdessen explizit geloescht, wenn sich der Tagesplan
      -- aendert (app.rpc_create_training_session/app.rpc_update_training_session).
      CASE WHEN p_session_id IS NULL THEN '[]'::jsonb ELSE COALESCE((
        SELECT jsonb_agg(d.hint_key ORDER BY d.hint_key)
          FROM app.session_hint_dismissals d
         WHERE d.session_id = p_session_id AND d.person_id = p.person_id
           AND d.team_id = p_team_id AND d.rule_version = 'v1'
           AND (d.hint_key NOT IN ('h1','h4') OR d.dismissed_at::date = current_date)
      ), '[]'::jsonb) END AS dismissed
    FROM players p
    LEFT JOIN LATERAL (
      SELECT b.median, b.sigma
        FROM app.baselines b
       WHERE b.person_id = p.person_id AND b.team_id = p_team_id
         AND b.metric = 'session_load' AND b.status = 'ok'
         AND b.as_of <= current_date
       ORDER BY b.as_of DESC
       LIMIT 1
    ) bl ON true
  ),
  zed AS (
    SELECT base.*,
      CASE WHEN bl_median IS NULL THEN NULL
           ELSE (v_plan - bl_median) / NULLIF(greatest(COALESCE(bl_sigma, 0), COALESCE(v_sigma_floor, 0)), 0)
      END AS z
    FROM base
  ),
  flags AS (
    SELECT zed.*,
      (band = 'low')                              AS raw_h1,
      (z IS NOT NULL AND z >= 1)                  AS raw_h2,
      (NOT has_checkin)                           AS raw_h3,
      (jsonb_array_length(dev_keys) > 0)          AS raw_h4,
      CASE
        WHEN z IS NULL THEN 'no_norm'
        WHEN z >= 2    THEN 'far_above'
        WHEN z >= 1    THEN 'above'
        WHEN z <= -1   THEN 'below'
        ELSE 'normal'
      END AS load_level
    FROM zed
  ),
  active AS (
    SELECT flags.*,
      (raw_h1 AND NOT (dismissed ? 'h1')) AS h1,
      (raw_h2 AND NOT (dismissed ? 'h2')) AS h2,
      raw_h3                            AS h3,
      (raw_h4 AND NOT (dismissed ? 'h4')) AS h4
    FROM flags
  )
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'person_id',               a.person_id,
             'suggestion',              CASE
                                          WHEN a.clearance = 'blocked'    THEN 'suspend'
                                          WHEN a.clearance = 'individual' THEN 'individual'
                                          WHEN a.clearance = 'limited'    THEN 'reduced'
                                          WHEN (a.h1 AND a.h2) OR (a.h2 AND a.z >= 2) THEN 'reduced'
                                          ELSE 'full'
                                        END,
             'source',                  CASE WHEN a.clearance IN ('blocked','individual','limited')
                                             THEN 'mirror' ELSE 'rule' END,
             'clearance',               a.clearance,
             'band',                    a.band,
             'load_level',              a.load_level,
             'released_deviation_keys', a.dev_keys,
             'has_checkin',             a.has_checkin,
             'hints',                   to_jsonb(array_remove(ARRAY[
                                          CASE WHEN a.h1 THEN 'h1' END,
                                          CASE WHEN a.h2 THEN 'h2' END,
                                          CASE WHEN a.h3 THEN 'h3' END,
                                          CASE WHEN a.h4 THEN 'h4' END
                                        ], NULL)),
             'dismissed_hints',         a.dismissed
           ) ORDER BY a.person_id), '[]'::jsonb)
    INTO v_result
    FROM active a;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION app._squad_check_v1(uuid, date, smallint, smallint, uuid) IS
  'AP-69 Regel v1 (deterministisch). Einzige Stelle der Entscheidungstabelle, benutzt von '
  'app.rpc_get_session_squad_check und app.rpc_squad_check_jev_context. Liefert keine Namen '
  'und keine rohe z-Zahl. Schreibt nichts. Punkt 85 (2026-09-29): h1/h4-Wegklicks zaehlen nur '
  'am selben Kalendertag, an dem ausgewertet wird (dismissed_at::date = current_date) -- beide '
  'Hinweise sind tagesaktuell, ein aelterer Wegklick bezieht sich auf einen ueberholten Stand. '
  'Siehe backend/40_squad_check.sql, backend/43_hint_dismissal_fixes.sql.';

REVOKE EXECUTE ON FUNCTION app._squad_check_v1(uuid, date, smallint, smallint, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. app.rpc_create_training_session — neue Einheit invalidiert h2-Wegklicks
--    ANDERER Einheiten desselben Tages
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

  -- Punkt 85 Fund 1 (Review 2026-09-29): die neue Einheit veraendert die
  -- Tageslast (h2) fuer JEDE andere Einheit desselben Tages. Ein bereits
  -- weggeklickter h2-Hinweis dieser anderen Einheiten muss neu bewertet
  -- werden. Die neue Einheit selbst hat noch keine Wegklicks.
  DELETE FROM app.session_hint_dismissals d
   USING app.training_sessions ts
   WHERE d.session_id = ts.id
     AND ts.team_id = v_team_id
     AND ts.id <> v_row.id
     AND ts.session_date = p_session_date
     AND d.hint_key = 'h2'
     AND d.rule_version = 'v1';

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only (coach/athletic_coach). '
  'team_id/created_by ausschliesslich aus den Auth-Helpern. Punkt 85 (2026-09-29): loescht '
  'h2-Wegklicks anderer Einheiten desselben Tages, deren Tageslast sich durch die neue Einheit '
  'aendert. Siehe backend/38_training_load.sql, backend/43_hint_dismissal_fixes.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_create_training_session(date, time, smallint, app.app_session_type, smallint, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. app.rpc_update_training_session — Aenderung invalidiert h2-Wegklicks
--    ANDERER Einheiten des alten UND neuen Tages
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
  v_team_id  uuid;
  v_old_date date;
  v_old      app.training_sessions%rowtype;
  v_row      app.training_sessions%rowtype;
  r          record;
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

  SELECT * INTO v_old
    FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id;
  v_old_date := v_old.session_date;

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

  -- AP-69 (Code-Review HOCH): ein Wegklick gilt fuer den Plan, gegen den er
  -- gemacht wurde. Aendert sich Datum, Dauer oder Intensitaet, gehen alle
  -- Wegklicks dieser Einheit, der Trainer sieht die Hinweise wieder.
  IF v_old.session_date      IS DISTINCT FROM v_row.session_date
     OR v_old.duration_min      IS DISTINCT FROM v_row.duration_min
     OR v_old.planned_intensity IS DISTINCT FROM v_row.planned_intensity THEN
    DELETE FROM app.session_hint_dismissals
     WHERE session_id = p_session_id AND team_id = v_team_id;

    -- Punkt 85 Fund 1 (Review 2026-09-29): dieselbe Aenderung veraendert die
    -- Tageslast (h2) fuer ANDERE Einheiten des alten und/oder neuen Tages.
    -- IN-Liste deckt beide Tage ab, auch wenn sie gleich sind (dann einmal).
    DELETE FROM app.session_hint_dismissals d
     USING app.training_sessions ts
     WHERE d.session_id = ts.id
       AND ts.team_id = v_team_id
       AND ts.id <> p_session_id
       AND ts.session_date IN (v_old.session_date, v_row.session_date)
       AND d.hint_key = 'h2'
       AND d.rule_version = 'v1';
  END IF;

  IF v_old_date IS DISTINCT FROM v_row.session_date THEN
    FOR r IN
      SELECT DISTINCT sr.person_id FROM app.session_rpe sr WHERE sr.session_id = p_session_id
    LOOP
      PERFORM app._compute_daily_session_load(r.person_id, v_old_date);
      PERFORM app._compute_daily_session_load(r.person_id, v_row.session_date);
    END LOOP;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

COMMENT ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) IS
  'Trainingsplanung (Modul 6, AP-68). Muster D, staff-only, nur eigenes Team. '
  'Bei geaendertem session_date wird daily_checkins.session_load fuer alten und neuen Tag '
  'jeder Person mit RPE auf dieser Einheit neu berechnet. Siehe backend/38_training_load.sql. '
  'AP-69: bei geaendertem Datum, Dauer oder Intensitaet werden alle Wegklicks der Einheit '
  '(app.session_hint_dismissals) geloescht. Punkt 85 (2026-09-29): zusaetzlich werden '
  'h2-Wegklicks ANDERER Einheiten des alten und neuen Tages geloescht, deren Tageslast sich '
  'mitaendert. Siehe backend/40_squad_check.sql, backend/43_hint_dismissal_fixes.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_update_training_session(uuid, date, time, smallint, app.app_session_type, smallint, text) TO authenticated;
