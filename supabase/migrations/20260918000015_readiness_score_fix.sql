-- Migration: 20260918000015_readiness_score_fix.sql
-- Fix: Readiness-Scores für migrierte Check-Ins berechnen + RPC-Patch
--
-- Problem:
--   compute_readiness() schreibt in app.readiness_score (singular)
--   rpc_morning_ops() liest public.readiness_scores (plural)
--   Beide Tabellen sind leer -> Dashboard zeigt keine Scores
--
-- Fix:
--   1. Readiness-Scores für alle 280 Check-Ins berechnen (selbe Formel wie compute_readiness)
--   2. In app.readiness_scores (plural) schreiben (Zieltabelle der Migration 09)
--   3. rpc_morning_ops() patchen: public.readiness_scores -> app.readiness_scores

-- 1. Readiness-Scores berechnen und schreiben
INSERT INTO app.readiness_scores (
  team_id, person_id, date, score_total, band, factors, computed_at, created_at
)
SELECT
  dc.team_id,
  dc.person_id,
  dc.date,
  round(
    (
      COALESCE(dc.sleep_quality, 5) +
      COALESCE(dc.recovery, 5) +
      COALESCE(dc.mental_mood, 5) +
      COALESCE(dc.mental_motivation, 5) +
      (10 - COALESCE(dc.mental_stress, 5))
    ) / 5.0
  , 2) as score_total,
  CASE
    WHEN (
      COALESCE(dc.sleep_quality, 5) +
      COALESCE(dc.recovery, 5) +
      COALESCE(dc.mental_mood, 5) +
      COALESCE(dc.mental_motivation, 5) +
      (10 - COALESCE(dc.mental_stress, 5))
    ) / 5.0 >= 7 THEN 'high'::app.app_readiness_band
    WHEN (
      COALESCE(dc.sleep_quality, 5) +
      COALESCE(dc.recovery, 5) +
      COALESCE(dc.mental_mood, 5) +
      COALESCE(dc.mental_motivation, 5) +
      (10 - COALESCE(dc.mental_stress, 5))
    ) / 5.0 >= 5 THEN 'moderate'::app.app_readiness_band
    ELSE 'low'::app.app_readiness_band
  END as band,
  jsonb_build_object(
    'sleep_quality', dc.sleep_quality,
    'recovery', dc.recovery,
    'mental_mood', dc.mental_mood,
    'mental_motivation', dc.mental_motivation,
    'mental_stress', dc.mental_stress,
    'training_readiness', dc.training_readiness
  ) as factors,
  now() as computed_at,
  now() as created_at
FROM app.daily_checkins dc
ON CONFLICT (person_id, date) DO UPDATE SET
  score_total = EXCLUDED.score_total,
  band = EXCLUDED.band,
  factors = EXCLUDED.factors;

-- 2. rpc_morning_ops() patchen: public.readiness_scores -> app.readiness_scores
CREATE OR REPLACE FUNCTION app.rpc_morning_ops()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, public, auth, pg_temp
AS $$
DECLARE
  v_team_id    uuid;
  v_kader_name text;
  v_members    jsonb;
BEGIN
  IF NOT app.auth_is_staff() THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;

  v_team_id := app.auth_team_id();

  SELECT t.name INTO v_kader_name
  FROM app.teams t
  WHERE t.id = v_team_id;

  SELECT coalesce(jsonb_agg(m.member ORDER BY m.jersey), '[]'::jsonb)
  INTO v_members
  FROM (
    SELECT
      coalesce(ap.shirt_number, 0) AS jersey,
      jsonb_build_object(
        'player', jsonb_build_object(
          'id', ap.id,
          'jersey', coalesce(ap.shirt_number, 0),
          'name', coalesce(ap.display_name, ''),
          'position', coalesce(ap.person_position, '')
        ),
        'readiness', jsonb_build_object(
          'value', rs.score_total,
          'band', rs.band,
          'factors', rs.factors
        ),
        'baseline', jsonb_build_object(
          'series', '[]'::jsonb,
          'rollingAvg', 0
        ),
        'medicalStatus', coalesce(mc.clearance_mapped, 'green'),
        'medicalClearance', mc.clearance_mapped,
        'attendance', 'anwesend',
        'todayEvent', 'none',
        'hasCheckIn', EXISTS (SELECT 1 FROM app.daily_checkins dc WHERE dc.person_id = ap.id AND dc.date = current_date)
      ) AS member
    FROM app.persons ap
    LEFT JOIN app.readiness_scores rs
      ON rs.person_id = ap.id AND rs.date = current_date
    LEFT JOIN LATERAL (
      SELECT CASE mcl.status
               WHEN 'full'       THEN 'frei'
               WHEN 'limited'    THEN 'eingeschraenkt'
               WHEN 'individual' THEN 'eingeschraenkt'
               WHEN 'blocked'    THEN 'gesperrt'
             END AS clearance_mapped
      FROM app.medical_clearances mcl
      WHERE mcl.person_id = ap.id
        AND mcl.valid_from <= now()
        AND (mcl.valid_to IS NULL OR mcl.valid_to > now())
      ORDER BY mcl.valid_from DESC
      LIMIT 1
    ) mc ON true
    WHERE ap.team_id = v_team_id
      AND ap.is_active = true
  ) m;

  RETURN jsonb_build_object(
    'kaderName', coalesce(v_kader_name, ''),
    'syncState', 'live',
    'asOf', to_char(current_date, 'YYYY-MM-DD'),
    'members', v_members
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION app.rpc_morning_ops() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.rpc_morning_ops() TO authenticated, anon, service_role;
