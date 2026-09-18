-- Migration: 20260918000014_data_reconcile_checkins.sql
-- Reconciles public.daily_checkins → app.daily_checkins with column mapping.
-- All 280 seed check-ins are mappable via:
--   daily_checkins.player_id → players.id → profiles.id → app.persons.auth_user_id
--
-- Column mapping:
--   player_id           → person_id (via auth_user_id join)
--   checkin_date        → date
--   sleep_hours         → sleep_duration_min
--   stress              → mental_stress
--   stimmung            → mental_mood
--   motivation          → mental_motivation

INSERT INTO app.daily_checkins (
  id, team_id, person_id, date,
  sleep_duration_min, sleep_quality, recovery, energy,
  mental_stress, mental_mood, mental_motivation,
  training_readiness, pain_max,
  submitted_at, created_at, updated_at
)
SELECT
  dc.id,
  ap.team_id,
  ap.id as person_id,
  dc.checkin_date as date,
  dc.sleep_hours as sleep_duration_min,
  dc.sleep_quality,
  dc.recovery,
  dc.energy,
  dc.stress as mental_stress,
  dc.stimmung as mental_mood,
  dc.motivation as mental_motivation,
  dc.training_readiness,
  (
    SELECT max(bm.pain)
    FROM public.daily_checkin_body_map bm
    WHERE bm.checkin_id = dc.id
  ) as pain_max,
  dc.created_at as submitted_at,
  dc.created_at,
  dc.updated_at
FROM public.daily_checkins dc
JOIN public.players p ON p.id = dc.player_id
JOIN public.profiles pr ON pr.player_id = p.id
JOIN app.persons ap ON ap.auth_user_id = pr.id
ON CONFLICT (person_id, date) DO UPDATE SET
  sleep_duration_min = EXCLUDED.sleep_duration_min,
  sleep_quality = EXCLUDED.sleep_quality,
  recovery = EXCLUDED.recovery,
  energy = EXCLUDED.energy,
  mental_stress = EXCLUDED.mental_stress,
  mental_mood = EXCLUDED.mental_mood,
  mental_motivation = EXCLUDED.mental_motivation,
  training_readiness = EXCLUDED.training_readiness,
  pain_max = EXCLUDED.pain_max,
  updated_at = now();
