-- Migration 20260919000019_checkin_submit_rpc.sql (AP-33, ADR-016)
-- Quelle: backend/11_checkin_submit.sql (identisch). Tests: backend/11_checkin_submit.pgtap.sql.
-- Schreibt keine Daten.

-- =============================================================================
-- 11_checkin_submit.sql — Check-In der Player-App direkt nach app.* (AP-33)
-- ADR-016 Weg (b): app.rpc_submit_checkin ist der einzige Schreibweg der App.
-- Kein Sync aus public.*, kein zweiter Speicherort fuer Gesundheitsdaten.
--
-- * Nur Rolle player mit bestaetigten Claims (Waechter Stufe 2, ADR-015).
-- * person_id und team_id kommen nur aus auth_person_id()/auth_team_id().
-- * Datum: heute oder bis zu 2 Tage zurueck (Offline-Nachtrag).
-- * Idempotent je (person_id, date): zweiter Aufruf am selben Tag ersetzt.
-- * Body Map als jsonb-Array [{region, pain, art}], pain_max wird berechnet.
-- * Score im selben Aufruf nach app.readiness_scores (Formel Migration 000015).
-- * Kein Freitext (Entscheidung Chris 2026-09-19, Datenminimierung).
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql. Idempotent.
-- =============================================================================

DROP FUNCTION IF EXISTS app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb);

CREATE OR REPLACE FUNCTION app.rpc_submit_checkin(
  p_date                date,
  p_sleep_duration_min  numeric DEFAULT NULL,
  p_sleep_quality       integer DEFAULT NULL,
  p_recovery            integer DEFAULT NULL,
  p_energy              integer DEFAULT NULL,
  p_mental_stress       integer DEFAULT NULL,
  p_mental_mood         integer DEFAULT NULL,
  p_mental_motivation   integer DEFAULT NULL,
  p_training_readiness  integer DEFAULT NULL,
  p_body_map            jsonb   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  v_person_id  uuid;
  v_team_id    uuid;
  v_pain_max   smallint;
  v_id         uuid;
  v_score      numeric;
BEGIN
  IF NOT app.auth_has_role('player') THEN
    PERFORM app.log_denial('daily_checkins.submit');
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.submit' USING errcode = '42501';
  END IF;

  v_person_id := app.auth_person_id();
  v_team_id := app.auth_team_id();

  IF p_date IS NULL OR p_date > current_date OR p_date < current_date - 2 THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.date' USING errcode = '42501';
  END IF;

  IF p_body_map IS NOT NULL THEN
    IF jsonb_typeof(p_body_map) <> 'array' THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_body_map) e
      WHERE jsonb_typeof(e) <> 'object'
         OR jsonb_typeof(e -> 'region') IS DISTINCT FROM 'string'
         OR (e ? 'pain' AND jsonb_typeof(e -> 'pain') NOT IN ('number', 'null'))
         OR (jsonb_typeof(e -> 'pain') = 'number' AND (e ->> 'pain')::numeric NOT BETWEEN 0 AND 10)
    ) THEN
      RAISE EXCEPTION 'INVALID: daily_checkins.body_map' USING errcode = '22023';
    END IF;

    SELECT max((e ->> 'pain')::numeric)::smallint
    INTO v_pain_max
    FROM jsonb_array_elements(p_body_map) e
    WHERE jsonb_typeof(e -> 'pain') = 'number';
  END IF;

  INSERT INTO app.daily_checkins (
    team_id, person_id, date, sleep_duration_min, sleep_quality, recovery,
    energy, mental_stress, mental_mood, mental_motivation, training_readiness,
    body_map, pain_max, submitted_at
  )
  VALUES (
    v_team_id, v_person_id, p_date, p_sleep_duration_min, p_sleep_quality, p_recovery,
    p_energy, p_mental_stress, p_mental_mood, p_mental_motivation, p_training_readiness,
    p_body_map, v_pain_max, now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    sleep_duration_min = EXCLUDED.sleep_duration_min,
    sleep_quality      = EXCLUDED.sleep_quality,
    recovery           = EXCLUDED.recovery,
    energy             = EXCLUDED.energy,
    mental_stress      = EXCLUDED.mental_stress,
    mental_mood        = EXCLUDED.mental_mood,
    mental_motivation  = EXCLUDED.mental_motivation,
    training_readiness = EXCLUDED.training_readiness,
    body_map           = EXCLUDED.body_map,
    pain_max           = EXCLUDED.pain_max,
    submitted_at       = EXCLUDED.submitted_at,
    updated_at         = now()
  WHERE app.daily_checkins.team_id = EXCLUDED.team_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'FORBIDDEN: daily_checkins.team' USING errcode = '42501';
  END IF;

  -- Score wie Migration 20260918000015 (deskriptiv, keine Diagnose).
  v_score := round((
      coalesce(p_sleep_quality, 5) +
      coalesce(p_recovery, 5) +
      coalesce(p_mental_mood, 5) +
      coalesce(p_mental_motivation, 5) +
      (10 - coalesce(p_mental_stress, 5))
    ) / 5.0, 2);

  INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors, computed_at)
  VALUES (
    v_team_id, v_person_id, p_date, v_score,
    CASE WHEN v_score >= 7 THEN 'high'::app.app_readiness_band
         WHEN v_score >= 5 THEN 'moderate'::app.app_readiness_band
         ELSE 'low'::app.app_readiness_band END,
    jsonb_build_object(
      'sleep_quality', p_sleep_quality,
      'recovery', p_recovery,
      'mental_mood', p_mental_mood,
      'mental_motivation', p_mental_motivation,
      'mental_stress', p_mental_stress,
      'training_readiness', p_training_readiness
    ),
    now()
  )
  ON CONFLICT (person_id, date) DO UPDATE SET
    score_total = EXCLUDED.score_total,
    band        = EXCLUDED.band,
    factors     = EXCLUDED.factors,
    computed_at = EXCLUDED.computed_at;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) IS
  'ADR-016: only write path for player check-ins. Player role with DB-confirmed claims, person/team from auth helpers, date today or up to 2 days back, upsert per (person_id, date), body_map jsonb array with pain_max, readiness score in the same call. No free text.';

REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION app.rpc_submit_checkin(date, numeric, integer, integer, integer, integer, integer, integer, integer, jsonb) TO authenticated;
