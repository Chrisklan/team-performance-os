-- =============================================================================
-- 36_mental_stress_direction.pgtap.sql — Richtungsfix mental_stress (Bridge,
-- Chris' Entscheidung 2026-09-27: Wortwahl "Mentale Anspannung", Richtung
-- lower_better statt higher_better)
--
-- Prueft backend/36_mental_stress_direction.sql / backend/33_baseline_engine.sql:
--   1. app.baseline_metric_config trägt fuer mental_stress direction=lower_better.
--   2. Baseline-Engine/Readiness-Score (backend/34_readiness_score.sql, app.
--      _compute_readiness_score): bei 28 Tagen konstant mental_stress=3 und
--      einem Tag mental_stress=9 (hohe Anspannung) muss der Faktor "mental"
--      UNTER 50 liegen (schlechter als der Durchschnitt).
--   3. Gegenprobe: ein Tag mit mental_stress=1 (kaum Anspannung) ergibt einen
--      Faktor "mental" UEBER 50 (besser als der Durchschnitt).
--   4. Regressionsschutz: die davon unabhaengige, unveraenderte alte Bandformel
--      "10 - mental_stress" (backend/11_checkin_submit.sql/backend/20_denial_
--      answer.sql, app.readiness_scores) bleibt korrekt -- score_total bei
--      Anspannung 9 ist kleiner als bei Anspannung 1.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(4);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f6000000-0000-0000-0000-000000000001','Team F6','Europe/Berlin');

-- -----------------------------------------------------------------------------
-- 1. baseline_metric_config: mental_stress ist lower_better
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT direction::text FROM app.baseline_metric_config WHERE metric = 'mental_stress'),
  'lower_better',
  'baseline_metric_config: mental_stress ist lower_better (Richtungsfix 2026-09-27)'
);

-- -----------------------------------------------------------------------------
-- 2. 28 Tage konstant mental_stress=3, ein Tag mental_stress=9 (hohe Anspannung)
--    -> Faktor "mental" unter 50 (schlechter als der eigene Durchschnitt).
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000001','f6000000-0000-0000-0000-000000000001','Spielerin F6a','stuermerin','f6100000-0000-0000-0000-000000000001',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, mental_stress)
SELECT 'f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000001',
       '2026-09-10'::date - g, 3
FROM generate_series(1,28) g;
INSERT INTO app.daily_checkins (team_id, person_id, date, mental_stress) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000001','2026-09-10', 9);

SELECT app._compute_readiness_score('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000001','2026-09-10');

SELECT cmp_ok(
  (SELECT points FROM app.readiness_factors_coach
    WHERE person_id = 'f6100000-0000-0000-0000-000000000001' AND date = '2026-09-10' AND factor = 'mental'),
  '<', 50::numeric,
  'hohe Anspannung (9 nach 28 Tagen konstant 3): Faktor mental liegt unter 50'
);

-- -----------------------------------------------------------------------------
-- 3. Gegenprobe: 28 Tage konstant mental_stress=3, ein Tag mental_stress=1
--    (kaum Anspannung) -> Faktor "mental" ueber 50.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000002','f6000000-0000-0000-0000-000000000001','Spielerin F6b','abwehr','f6100000-0000-0000-0000-000000000002',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000002','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, mental_stress)
SELECT 'f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000002',
       '2026-09-10'::date - g, 3
FROM generate_series(1,28) g;
INSERT INTO app.daily_checkins (team_id, person_id, date, mental_stress) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000002','2026-09-10', 1);

SELECT app._compute_readiness_score('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000002','2026-09-10');

SELECT cmp_ok(
  (SELECT points FROM app.readiness_factors_coach
    WHERE person_id = 'f6100000-0000-0000-0000-000000000002' AND date = '2026-09-10' AND factor = 'mental'),
  '>', 50::numeric,
  'kaum Anspannung (1 nach 28 Tagen konstant 3): Faktor mental liegt ueber 50'
);

-- -----------------------------------------------------------------------------
-- 4. Regressionsschutz: die alte, unabhaengige Bandformel "10 - mental_stress"
--    (app.readiness_scores, backend/11_checkin_submit.sql) bleibt unveraendert
--    korrekt -- sie liest app.baseline_metric_config nicht.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, auth_user_id, is_active) VALUES
  ('f6100000-0000-0000-0000-000000000003','f6000000-0000-0000-0000-000000000001','Spielerin F6c','f6100000-0000-0000-0000-000000000003',true),
  ('f6100000-0000-0000-0000-000000000004','f6000000-0000-0000-0000-000000000001','Spielerin F6d','f6100000-0000-0000-0000-000000000004',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000003','player', now() - interval '1 day', NULL),
  ('f6000000-0000-0000-0000-000000000001','f6100000-0000-0000-0000-000000000004','player', now() - interval '1 day', NULL);

CREATE OR REPLACE FUNCTION app._t36_jwt(p_sub text, p_role text, p_team text DEFAULT 'f6000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

SET ROLE authenticated;
SELECT app._t36_jwt('f6100000-0000-0000-0000-000000000003', 'player');
SELECT app.rpc_submit_checkin(current_date, 480, 8, 8, 8, 9, 8, 8, 8);
SELECT app._t36_jwt('f6100000-0000-0000-0000-000000000004', 'player');
SELECT app.rpc_submit_checkin(current_date, 480, 8, 8, 8, 1, 8, 8, 8);
RESET ROLE;

SELECT cmp_ok(
  (SELECT score_total FROM app.readiness_scores WHERE person_id = 'f6100000-0000-0000-0000-000000000003' AND date = current_date),
  '<',
  (SELECT score_total FROM app.readiness_scores WHERE person_id = 'f6100000-0000-0000-0000-000000000004' AND date = current_date),
  'alte Bandformel unveraendert: score_total bei Anspannung 9 ist kleiner als bei Anspannung 1'
);

SELECT * FROM finish();
ROLLBACK;
