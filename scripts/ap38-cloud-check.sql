-- AP-38: Cloud-Beleg fuer den Gate-Test (nur lesend). Vorher und nachher ausfuehren, Ausgaben vergleichen.
--   supabase db query --linked -f scripts/ap38-cloud-check.sql
-- Person: spieler@c-klan.de (per auth_user_id aufgeloest). Datum: heutiges UTC-Datum (ADR-016, Zeitzone offen).
-- Sentinel Werte und Erwartung: player docs/offline-gate-checklist.md (300 Min, Qualitaet 4, pain_max 4, Score 5,8, moderate).
WITH p AS (
  SELECT ps.id
  FROM app.persons ps
  JOIN auth.users u ON u.id = ps.auth_user_id
  WHERE u.email = 'spieler@c-klan.de'
)
SELECT
  (SELECT count(*) FROM app.daily_checkins)                                     AS checkins_gesamt,
  (SELECT count(*) FROM app.readiness_scores)                                   AS scores_gesamt,
  (SELECT count(*) FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS checkins_person_heute,
  (SELECT d.sleep_duration_min FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS schlaf_min,
  (SELECT d.sleep_quality FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS schlaf_qualitaet,
  (SELECT d.recovery FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS recovery,
  (SELECT d.mental_mood FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS stimmung,
  (SELECT d.mental_stress FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS stress,
  (SELECT d.mental_motivation FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS motivation,
  (SELECT d.energy FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS energie,
  (SELECT d.training_readiness FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS bereitschaft,
  (SELECT d.pain_max FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS pain_max,
  (SELECT d.submitted_at FROM app.daily_checkins d, p WHERE d.person_id = p.id
     AND d.date = (now() AT TIME ZONE 'utc')::date)                             AS eingereicht_um,
  (SELECT r.score_total FROM app.readiness_scores r, p WHERE r.person_id = p.id
     AND r.date = (now() AT TIME ZONE 'utc')::date)                             AS score,
  (SELECT r.band FROM app.readiness_scores r, p WHERE r.person_id = p.id
     AND r.date = (now() AT TIME ZONE 'utc')::date)                             AS band,
  (SELECT count(*) FROM app.audit_log)                                          AS audit_log,
  (SELECT count(*) FROM public.daily_checkins)                                  AS public_daily_checkins;
