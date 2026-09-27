-- =============================================================================
-- 40_squad_check.sql — AP-69 Plan gegen Zustand, Teil 1: Regelpruefung v1
--
-- Zuschnitt final (mit Chris abgestimmt, 2026-09-27, zwei Plan-Durchlaeufe):
--   * Eine geplante Einheit (gespeichert oder Entwurf) wird je Spielerin gegen
--     ihren heutigen Zustand gehalten. Ergebnis je Person: ein Vorschlag aus
--     genau vier Spalten (volle Gruppe/reduziert/individuell/aussetzen), die
--     Quelle des Vorschlags (mirror = Spiegel der aerztlichen Freigabe, rule =
--     Regel v1), aktive und weggeklickte Hinweise, Rohklassen.
--   * ADR-019 §3.2: "Rechnen ist Statistik". Die Regel ist eine feste,
--     deterministische Entscheidungstabelle (Version v1), kein Modell. Die
--     JEV-Stufe (41_jev_switch_model_call_log.sql) setzt nur auf dieser Regel
--     auf und kann nie mehr als "reduziert" vorschlagen.
--   * ADR-019 §5.1 Zeile AP-69: "Aussetzen" nur als Spiegel einer aerztlichen
--     Freigabe, nie aus Modell oder Statistik abgeleitet. Die Regel eskaliert
--     aus der Statistik hoechstens auf "reduziert".
--   * ADR-019 §3.4 I1/I6: nur Eingaben, die der Trainer laut Rollenmatrix
--     ohnehin sieht. Das sind Freigabestatus (wie app.rpc_get_clearance),
--     Readiness-BAND (nie score_total/factors), Check-in ja/nein (wie
--     hasCheckIn in app.rpc_morning_ops), die eigene session_load-Baseline und
--     FREIGEGEBENE Lastabweichungen ohne pain_max -- letztere nur, wenn das
--     Modul loaddeviation_enabled fuer das Team an ist. Ohne das Modul sieht
--     der Trainer ueber keine Tuer etwas von Abweichungen, also auch hier nicht
--     (Fund aus der Planungsphase, gilt fuer H4 ohne Ausnahme).
--
-- Entscheidungstabelle Regel v1 (deterministisch, Reihenfolge bindend):
--   1. Freigabe blocked    -> suspend  (aussetzen),  Quelle mirror
--   2. Freigabe individual -> individual,            Quelle mirror
--   3. Freigabe limited    -> reduced  (reduziert),  Quelle mirror
--   4. Freigabe full oder keine geltende Zeile -> full (volle Gruppe), Quelle
--      rule, plus Hinweise:
--        h1  Readiness-Band heute low
--        h2  geplante Tageslast z >= +1 gegen die eigene session_load-Baseline
--            z = (Plan - median) / greatest(sigma, sigma_floor)
--        h3  heute kein Check-in (checkin_submitted_at IS NULL). Reiner
--            Info-Hinweis, loest NIE einen Vorschlag aus, nicht wegklickbar.
--        h4  freigegebene Lastabweichung in den letzten 7 Tagen (heute
--            eingeschlossen), metric <> pain_max, nur bei Modul an
--      Vorschlag reduced, wenn (h1 UND h2) ODER (h2 mit z >= +2). Weiter geht
--      keine Regel, nie auf individual/suspend aus der Statistik.
--   Weggeklickte Hinweise (app.session_hint_dismissals) zaehlen fuer die
--   Eskalation nicht mehr: wer h2 wegklickt, bekommt fuer diese Person wieder
--   "volle Gruppe". Ein Spiegel ist davon unberuehrt und nie wegklickbar.
--
-- Geplante Tageslast: planned_intensity x duration_min, Summe ueber alle
-- Einheiten des Teams an p_date. Die geprueften Formularwerte zaehlen als eine
-- Einheit (auch als Entwurf), p_session_id schliesst die gespeicherte Fassung
-- derselben Einheit aus der Summe aus (sonst zaehlte sie doppelt). Andere
-- Einheiten ohne planned_intensity tragen nichts bei (unbekannte Plan-
-- Intensitaet ist keine Last 0, aber auch keine Schaetzung).
-- Baseline: app.baselines, metric session_load, juengstes as_of <=
-- current_date mit status ok. Keine solche Zeile -> Laststufe no_norm, h2 nie.
--
-- Muster D (wie 33/35/38):
--   1. VOLATILE, app-Funktion und Tuer.
--   2. Kein RAISE im Ablehnungszweig, app.deny. RAISE nur fuer genuine
--      Eingabefehler (22023) und "nicht gefunden" (P0002, fremde oder
--      unbekannte Einheit, wie app.rpc_get_deviation_statement).
--   3. team_id/dismissed_by ausschliesslich aus den Auth-Helpern.
--   4. Erste Bedingung: app.auth_team_id() IS NULL -> deny.
--
-- Kein access_log-Eintrag in rpc_get_session_squad_check: die Pruefung ist
-- eine team-weite Uebersicht wie app.rpc_morning_ops/app.rpc_list_team_members
-- (bewusst kein access_log, dieselbe Begruendung wie dort), und sie liefert
-- nichts, was die Kaderuebersicht nicht schon zeigt (Band, Freigabe-Badge,
-- Check-in ja/nein) ausser freigegebenen Abweichungen, die der Trainer ueber
-- rpc_get_deviations_today ebenfalls ohne access_log sieht.
--
-- Voraussetzung: 08/09 (Auth-Helfer, readiness_scores, medical_clearances),
-- 20 (app.deny/app.is_denial), 27 (app.auth_target_is_team_player), 33
-- (app.baselines, app.baseline_metric_config), 35 (app.module_flags,
-- app.load_deviations mit metric/statement_key), 38 (app.training_sessions,
-- daily_checkins.checkin_submitted_at). Idempotent.
-- Tests: backend/40_squad_check.pgtap.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. app.session_hint_dismissals — weggeklickte Hinweise, teamweit, dauerhaft
-- -----------------------------------------------------------------------------
-- Ein Wegklick gilt fuer die Einheit und die Person, nicht nur fuer den
-- wegklickenden Trainer: das ganze Trainerteam sieht denselben Stand.
-- rule_version haelt fest, gegen welche Regelfassung weggeklickt wurde. Eine
-- kuenftige Regel v2 zeigt einen unter v1 weggeklickten Hinweis wieder an,
-- weil er dort etwas anderes bedeuten kann.
--
-- dismissed_by ON DELETE SET NULL: die Personenzeile wird im Projekt nie
-- geloescht (Crypto Shredding, 14/30), deshalb setzt app.rpc_shred_person
-- dismissed_by zusaetzlich selbst auf NULL (41_jev_switch_model_call_log.sql).
-- Der Wegklick selbst bleibt stehen: er gehoert zur Einheit und zur
-- betroffenen Spielerin, nicht zur handelnden Person.

CREATE TABLE IF NOT EXISTS app.session_hint_dismissals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id       uuid NOT NULL REFERENCES app.teams(id) ON DELETE CASCADE,
  session_id    uuid NOT NULL REFERENCES app.training_sessions(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES app.persons(id) ON DELETE CASCADE,
  hint_key      text NOT NULL CHECK (hint_key IN ('h1','h2','h4','j1')),
  rule_version  text NOT NULL,
  dismissed_by  uuid REFERENCES app.persons(id) ON DELETE SET NULL,
  dismissed_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, person_id, hint_key, rule_version)
);

CREATE INDEX IF NOT EXISTS session_hint_dismissals_team_session_idx
  ON app.session_hint_dismissals (team_id, session_id);

COMMENT ON TABLE app.session_hint_dismissals IS
  'AP-69: weggeklickte Hinweise je Einheit und Person, teamweit sichtbar. Nur ueber '
  'app.rpc_dismiss_session_hint/app.rpc_restore_session_hint beschreibbar, nur ueber '
  'app.rpc_get_session_squad_check lesbar. Freigabe-Spiegel sind nie wegklickbar.';

ALTER TABLE app.session_hint_dismissals ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.session_hint_dismissals FORCE ROW LEVEL SECURITY;

-- Kein direkter Tabellenzugriff, keine Policy: jeder Weg laeuft ueber die
-- SECURITY DEFINER Tueren (wie app.module_flags in 35_load_deviation.sql).
REVOKE ALL ON app.session_hint_dismissals FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. app._squad_check_v1 — die Regel selbst, EINE Stelle fuer RPC und JEV-Tuer
-- -----------------------------------------------------------------------------
-- Rueckgabe: jsonb-Array, ein Objekt je aktiver Spielerin des Teams, sortiert
-- nach person_id (stabil, nicht nach Name: die Funktion liefert keine Namen,
-- damit die JEV-Tuer sie gar nicht erst in der Hand hat).
--   person_id, suggestion (full|reduced|individual|suspend), source
--   (mirror|rule), clearance (Freigabestatus oder NULL), band (low|moderate|
--   high oder NULL), load_level (far_above|above|normal|below|no_norm),
--   released_deviation_keys (statement_key-Liste, leer bei Modul aus),
--   has_checkin (boolean), hints (aktive Hinweise), dismissed_hints
--   (weggeklickte Hinweise dieser Einheit, inklusive j1).
-- Die rohe z-Zahl verlaesst diese Funktion nie, nur die Laststufe.
--
-- p_team_id kommt ausschliesslich von den aufrufenden Tueren (app.
-- auth_team_id()). Das Modul loaddeviation_enabled wird direkt fuer p_team_id
-- gelesen: das ist fuer jeden Aufrufer dasselbe wie app.module_enabled(), weil
-- p_team_id = app.auth_team_id(), bindet die Regel aber nicht an JWT-Claims.
--
-- Schreibt nichts (kein INSERT/UPDATE/DELETE), insbesondere nie auf
-- app.medical_clearances oder app.readiness_scores (ADR-019 T2, pgTAP-geprueft).

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
      -- Freigabe: dieselbe Auswahlregel wie app.rpc_get_clearance (samt id-Tiebreaker).
      (SELECT c.status FROM app.medical_clearances c
        WHERE c.person_id = p.person_id AND c.team_id = p_team_id
          AND c.valid_from <= current_date
          AND (c.valid_to IS NULL OR c.valid_to >= current_date)
        ORDER BY c.valid_from DESC, c.id DESC
        LIMIT 1) AS clearance,
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
      CASE WHEN p_session_id IS NULL THEN '[]'::jsonb ELSE COALESCE((
        SELECT jsonb_agg(d.hint_key ORDER BY d.hint_key)
          FROM app.session_hint_dismissals d
         WHERE d.session_id = p_session_id AND d.person_id = p.person_id
           AND d.team_id = p_team_id AND d.rule_version = 'v1'
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
  'und keine rohe z-Zahl. Schreibt nichts. Siehe backend/40_squad_check.sql.';

REVOKE EXECUTE ON FUNCTION app._squad_check_v1(uuid, date, smallint, smallint, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. app._squad_check_clearance — Freigabestatus einer Person (fuer den
--    Spiegel-Ausschluss beim Wegklicken), dieselbe Auswahlregel wie oben
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._squad_check_clearance(p_team_id uuid, p_person_id uuid)
RETURNS app.app_clearance
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT c.status FROM app.medical_clearances c
   WHERE c.person_id = p_person_id AND c.team_id = p_team_id
     AND c.valid_from <= current_date
     AND (c.valid_to IS NULL OR c.valid_to >= current_date)
   ORDER BY c.valid_from DESC, c.id DESC
   LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION app._squad_check_clearance(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. app.rpc_get_session_squad_check — Muster D, nur Staff, eigenes Team
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.rpc_get_session_squad_check(
  p_session_date       date,
  p_duration_min       smallint,
  p_planned_intensity  smallint,
  p_session_id         uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id  uuid;
  v_rows     jsonb;
  v_plan     numeric;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('squad_check.get', 'FORBIDDEN: squad_check.get');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('squad_check.get', 'FORBIDDEN: squad_check.get');
  END IF;

  v_team_id := app.auth_team_id();

  IF p_session_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id
  ) THEN
    RAISE EXCEPTION 'NOT_FOUND: training_sessions' USING errcode = 'P0002';
  END IF;

  IF p_session_date IS NULL THEN
    RAISE EXCEPTION 'INVALID: squad_check.session_date' USING errcode = '22023';
  END IF;

  IF p_duration_min IS NULL OR p_duration_min <= 0 OR p_duration_min > 300 THEN
    RAISE EXCEPTION 'INVALID: squad_check.duration_min' USING errcode = '22023';
  END IF;

  IF p_planned_intensity IS NULL OR p_planned_intensity NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'INVALID: squad_check.planned_intensity' USING errcode = '22023';
  END IF;

  v_rows := app._squad_check_v1(v_team_id, p_session_date, p_duration_min, p_planned_intensity, p_session_id);

  v_plan := (p_planned_intensity::numeric * p_duration_min::numeric)
          + COALESCE((
              SELECT sum(ts.planned_intensity::numeric * ts.duration_min::numeric)
                FROM app.training_sessions ts
               WHERE ts.team_id = v_team_id AND ts.session_date = p_session_date
                 AND ts.planned_intensity IS NOT NULL
                 AND (p_session_id IS NULL OR ts.id <> p_session_id)
            ), 0);

  -- Namen und Rueckennummer erst hier, fuer die Oberflaeche des Trainers (sieht er
  -- ohnehin in app.rpc_morning_ops). Die Regel selbst kennt sie nicht.
  RETURN jsonb_build_object(
    'rule_version',     'v1',
    'session_id',       p_session_id,
    'session_date',     p_session_date,
    'planned_day_load', v_plan,
    'athletes', COALESCE((
      SELECT jsonb_agg(
               r || jsonb_build_object(
                 'display_name', COALESCE(pe.display_name, ''),
                 'jersey',       pe.shirt_number
               ) ORDER BY pe.shirt_number NULLS LAST, pe.display_name)
        FROM jsonb_array_elements(v_rows) r
        JOIN app.persons pe ON pe.id = (r ->> 'person_id')::uuid AND pe.team_id = v_team_id
    ), '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_get_session_squad_check(date, smallint, smallint, uuid) IS
  'AP-69 Plan gegen Zustand, Regel v1. Muster D, nur Staff (coach/athletic_coach), eigenes Team. '
  'p_session_id schliesst die eigene Einheit aus der Tagessumme aus und wendet gespeicherte '
  'Wegklicks an, fremde/unbekannte Einheit P0002. Team-weite Uebersicht ohne access_log '
  '(wie rpc_morning_ops). Siehe backend/40_squad_check.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_get_session_squad_check(date, smallint, smallint, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_get_session_squad_check(date, smallint, smallint, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. app.rpc_dismiss_session_hint / app.rpc_restore_session_hint
-- -----------------------------------------------------------------------------
-- Geschlossene Liste h1/h2/h4/j1. h3 ist Info, kein Vorschlag, nichts zum
-- Wegklicken. Ein Freigabe-Spiegel (blocked/individual/limited) ist nie
-- wegklickbar: die Funktion lehnt jede Person mit Spiegel-Vorschlag ab, BEVOR
-- sie einen Datensatz anlegt -- auch fuer h1/h2/h4, damit fuer diese Person
-- gar kein Wegklick existiert, der den Eindruck erwecken koennte, der Spiegel
-- sei verhandelbar.

CREATE OR REPLACE FUNCTION app.rpc_dismiss_session_hint(
  p_session_id uuid,
  p_person_id  uuid,
  p_hint_key   text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('session_hint.dismiss', 'FORBIDDEN: session_hint.dismiss');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('session_hint.dismiss', 'FORBIDDEN: session_hint.dismiss');
  END IF;

  v_team_id := app.auth_team_id();

  IF p_hint_key IS NULL OR p_hint_key NOT IN ('h1','h2','h4','j1') THEN
    RAISE EXCEPTION 'INVALID: session_hint.hint_key' USING errcode = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id
  ) THEN
    RAISE EXCEPTION 'NOT_FOUND: training_sessions' USING errcode = 'P0002';
  END IF;

  IF NOT app.auth_target_is_team_player(p_person_id) THEN
    RETURN app.deny('session_hint.dismiss', 'FORBIDDEN: session_hint.dismiss');
  END IF;

  IF app._squad_check_clearance(v_team_id, p_person_id) IN ('blocked','individual','limited') THEN
    RETURN app.deny('session_hint.dismiss', 'FORBIDDEN: session_hint.mirror');
  END IF;

  INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version, dismissed_by)
  VALUES (v_team_id, p_session_id, p_person_id, p_hint_key, 'v1', app.auth_person_id())
  ON CONFLICT (session_id, person_id, hint_key, rule_version) DO NOTHING;

  RETURN jsonb_build_object(
    'session_id', p_session_id, 'person_id', p_person_id,
    'hint_key', p_hint_key, 'rule_version', 'v1', 'dismissed', true
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_dismiss_session_hint(uuid, uuid, text) IS
  'AP-69: Hinweis fuer Einheit und Person wegklicken, teamweit, dauerhaft. Muster D, nur Staff, '
  'eigenes Team. hint_key aus h1/h2/h4/j1, sonst 22023. Freigabe-Spiegel nie wegklickbar (deny). '
  'Siehe backend/40_squad_check.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_dismiss_session_hint(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_dismiss_session_hint(uuid, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION app.rpc_restore_session_hint(
  p_session_id uuid,
  p_person_id  uuid,
  p_hint_key   text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_team_id uuid;
  v_count   integer;
BEGIN
  IF app.auth_team_id() IS NULL THEN
    RETURN app.deny('session_hint.restore', 'FORBIDDEN: session_hint.restore');
  END IF;

  IF NOT app.auth_is_staff() THEN
    RETURN app.deny('session_hint.restore', 'FORBIDDEN: session_hint.restore');
  END IF;

  v_team_id := app.auth_team_id();

  IF p_hint_key IS NULL OR p_hint_key NOT IN ('h1','h2','h4','j1') THEN
    RAISE EXCEPTION 'INVALID: session_hint.hint_key' USING errcode = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM app.training_sessions WHERE id = p_session_id AND team_id = v_team_id
  ) THEN
    RAISE EXCEPTION 'NOT_FOUND: training_sessions' USING errcode = 'P0002';
  END IF;

  DELETE FROM app.session_hint_dismissals
   WHERE session_id = p_session_id AND person_id = p_person_id
     AND hint_key = p_hint_key AND rule_version = 'v1' AND team_id = v_team_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'session_id', p_session_id, 'person_id', p_person_id,
    'hint_key', p_hint_key, 'rule_version', 'v1', 'restored', v_count > 0
  );
END;
$$;

COMMENT ON FUNCTION app.rpc_restore_session_hint(uuid, uuid, text) IS
  'AP-69: weggeklickten Hinweis wiederherstellen. Muster D, nur Staff, eigenes Team. '
  'Siehe backend/40_squad_check.sql.';

REVOKE EXECUTE ON FUNCTION app.rpc_restore_session_hint(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION app.rpc_restore_session_hint(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. Die Tueren in public
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_get_session_squad_check(
  p_session_date       date,
  p_duration_min       smallint,
  p_planned_intensity  smallint,
  p_session_id         uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_get_session_squad_check(p_session_date, p_duration_min, p_planned_intensity, p_session_id);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_dismiss_session_hint(p_session_id uuid, p_person_id uuid, p_hint_key text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_dismiss_session_hint(p_session_id, p_person_id, p_hint_key);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.rpc_restore_session_hint(p_session_id uuid, p_person_id uuid, p_hint_key text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  v_result := app.rpc_restore_session_hint(p_session_id, p_person_id, p_hint_key);
  IF app.is_denial(v_result) THEN PERFORM set_config('response.status', '403', true); END IF;
  RETURN v_result;
END; $$;

COMMENT ON FUNCTION public.rpc_get_session_squad_check(date, smallint, smallint, uuid) IS 'API-Tuer fuer app.rpc_get_session_squad_check. Invoker, nur authenticated. AP-69.';
COMMENT ON FUNCTION public.rpc_dismiss_session_hint(uuid, uuid, text) IS 'API-Tuer fuer app.rpc_dismiss_session_hint. Invoker, nur authenticated. AP-69.';
COMMENT ON FUNCTION public.rpc_restore_session_hint(uuid, uuid, text) IS 'API-Tuer fuer app.rpc_restore_session_hint. Invoker, nur authenticated. AP-69.';

REVOKE EXECUTE ON FUNCTION public.rpc_get_session_squad_check(date, smallint, smallint, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_dismiss_session_hint(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_restore_session_hint(uuid, uuid, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.rpc_get_session_squad_check(date, smallint, smallint, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_dismiss_session_hint(uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_restore_session_hint(uuid, uuid, text) TO authenticated, service_role;
