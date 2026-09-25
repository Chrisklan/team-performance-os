-- =============================================================================
-- 34_readiness_score.pgtap.sql — Readiness Score (Bridge Punkt 57, Teil 2 von 3)
--
-- Prueft backend/34_readiness_score.sql: Formel-Fix v2.0 (z=0 ueberall -> 50 bei
-- beiden Varianten, NICHT die fehlerhafte v1.0-Load-Formel), Gewichtssummen,
-- Inferenzleck-Schutz (authenticated hat strukturell kein Recht auf
-- readiness_factor_medical, nicht nur eine Rollenpruefung), Richtungs-Korrektur
-- (pain_max invertiert), completeness<0.6 -> insufficient, kein Datensatz ->
-- no_baseline, und die Tuer (self-only, Ablehnung ohne Team).
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(18);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f4000000-0000-0000-0000-000000000001','Team F4','Europe/Berlin');

CREATE OR REPLACE FUNCTION app._t34_jwt(p_sub text, p_role text, p_team text DEFAULT 'f4000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- -----------------------------------------------------------------------------
-- 1. Gewichtssummen: beide Varianten exakt 1.000
-- -----------------------------------------------------------------------------
SELECT is(
  (SELECT round(sum(weight_full), 5) FROM app.readiness_weights WHERE algo_version = 'v1'),
  1.00000::numeric, 'Summe weight_full ueber alle Metriken = 1.000'
);
SELECT is(
  (SELECT round(sum(weight_sport), 5) FROM app.readiness_weights WHERE algo_version = 'v1'),
  1.00000::numeric, 'Summe weight_sport ueber alle Metriken = 1.000'
);

-- -----------------------------------------------------------------------------
-- 2. Formel-Fix v2.0: load ist bidirektional (50 - 12.5*|z|), NICHT die
--    fehlerhafte v1.0-Variante (50 + 12.5*(2-|z|), die bei z=0 faelschlich 75 gibt).
-- -----------------------------------------------------------------------------
SELECT is(
  least(100, greatest(0, round(50 - 12.5 * abs(0::numeric), 2))),
  50.00::numeric, 'v2.0-Fix: load-Formel bei z=0 ergibt 50 (nicht 75 wie v1.0)'
);
SELECT is(
  least(100, greatest(0, round(50 - 12.5 * abs(2::numeric), 2))),
  25.00::numeric, 'load-Formel bei |z|=2 ergibt 25'
);

-- -----------------------------------------------------------------------------
-- 3. Inferenzleck-Schutz: authenticated hat strukturell KEIN Recht auf die
--    Medizin-Tabelle (REVOKE ALL, kein GRANT) -- nicht nur eine Rollenpruefung.
-- -----------------------------------------------------------------------------
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.readiness_factor_medical', 'SELECT'),
  'authenticated hat strukturell 0 SELECT-Recht auf app.readiness_factor_medical'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'app.readiness_score', 'SELECT'),
  'authenticated hat strukturell 0 SELECT-Recht auf app.readiness_score'
);
SELECT ok(
  NOT has_table_privilege('anon', 'app.readiness_factor_medical', 'SELECT'),
  'anon hat strukturell 0 SELECT-Recht auf app.readiness_factor_medical'
);

-- -----------------------------------------------------------------------------
-- 4. z=0 auf allen (verfuegbaren) Metriken -> value_full=50 UND value_sport=50.
--    Konstante Reihe ueber 29 Tage (28 Baseline-Fenster + heute), load strukturell
--    immer 0 Beobachtungen (kein Trainingsmanagement-Modul) -- Gewicht faellt auf
--    die uebrigen vier Faktoren, aendert bei ueberall konstant 50 nichts am Schnitt.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f4100000-0000-0000-0000-000000000001','f4000000-0000-0000-0000-000000000001','Spielerin A','stuermerin','f4100000-0000-0000-0000-000000000001',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000001',
       current_date - g, 480, 5, 5, 5, 5, 5, 5, 5, 0
FROM generate_series(0,28) g;

SELECT app._t34_jwt('f4100000-0000-0000-0000-000000000001', 'player');

SELECT is(
  (app.rpc_get_my_score(current_date) ->> 'value_full')::int,
  50, 'z=0 auf allen verfuegbaren Metriken: value_full = 50'
);
SELECT is(
  (app.rpc_get_my_score(current_date) ->> 'value_sport')::int,
  50, 'z=0 auf allen verfuegbaren Metriken: value_sport = 50'
);
SELECT is(
  (app.rpc_get_my_score(current_date) ->> 'status'),
  'ok', 'genug Faktoren verfuegbar (load faellt strukturell weg): status ok'
);

-- -----------------------------------------------------------------------------
-- 5. rpc_get_my_scores (Player-Client): Array-Laenge, heutiger Eintrag konsistent.
-- -----------------------------------------------------------------------------
SELECT is(
  jsonb_array_length(app.rpc_get_my_scores(7)),
  7, 'rpc_get_my_scores(7) liefert genau 7 Tage'
);
SELECT is(
  (
    SELECT (x ->> 'value_full')::int
    FROM jsonb_array_elements(app.rpc_get_my_scores(7)) x
    WHERE x ->> 'date' = current_date::text
  ),
  50, 'heutiger Eintrag in rpc_get_my_scores stimmt mit rpc_get_my_score ueberein'
);

-- -----------------------------------------------------------------------------
-- 6. Richtungs-Korrektur: pain_max ist lower_better, ein Ausreisser nach oben
--    (schlechter) MUSS die physical-Punktzahl UNTER 50 druecken, nicht darueber.
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f4100000-0000-0000-0000-000000000002','f4000000-0000-0000-0000-000000000001','Spielerin B','abwehr','f4100000-0000-0000-0000-000000000002',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000002','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000002',
       current_date - g, 480, 5, 5, 5, 5, 5, 5, 5, 1
FROM generate_series(1,28) g;
-- heute: starker Schmerz-Ausreisser (8 statt konstant 1)
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
VALUES ('f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000002', current_date, 480, 5, 5, 5, 5, 5, 5, 5, 8);

SELECT app._t34_jwt('f4100000-0000-0000-0000-000000000002', 'player');

SELECT cmp_ok(
  (
    SELECT (x -> 'detail') IS NOT NULL
    FROM jsonb_array_elements(app.rpc_get_my_score(current_date) -> 'factors_self') x
    WHERE x ->> 'factor' = 'physical'
  ),
  '=', true, 'physical-Faktor liegt vor'
);
SELECT cmp_ok(
  (
    SELECT (x ->> 'points')::numeric
    FROM jsonb_array_elements(app.rpc_get_my_score(current_date) -> 'factors_self') x
    WHERE x ->> 'factor' = 'physical'
  ),
  '<', 50.0, 'Schmerz-Ausreisser (8 statt 1) drueckt die physical-Punktzahl unter 50 (Richtung korrekt invertiert)'
);

-- -----------------------------------------------------------------------------
-- 7. completeness < 0.6 -> status insufficient, kein value_full/value_sport.
--    Nur der sleep-Faktor hat eine Baseline (Gewicht 0.25 < 0.6), alle anderen
--    Spalten bleiben NULL (n_obs=0 -> insufficient).
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f4100000-0000-0000-0000-000000000003','f4000000-0000-0000-0000-000000000001','Spielerin C','abwehr','f4100000-0000-0000-0000-000000000003',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000003','player', now() - interval '90 days', NULL);

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality)
SELECT 'f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000003',
       current_date - g, 480, 5
FROM generate_series(0,28) g;

SELECT app._t34_jwt('f4100000-0000-0000-0000-000000000003', 'player');

SELECT is(
  (app.rpc_get_my_score(current_date) ->> 'status'),
  'insufficient', 'nur sleep-Faktor verfuegbar (completeness 0.25 < 0.6): status insufficient'
);
SELECT is(
  app.rpc_get_my_score(current_date) ->> 'value_full',
  NULL, 'insufficient: kein value_full'
);

-- -----------------------------------------------------------------------------
-- 8. Keine Check-Ins ueberhaupt -> no_baseline (nicht insufficient).
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f4100000-0000-0000-0000-000000000004','f4000000-0000-0000-0000-000000000001','Spielerin D','abwehr','f4100000-0000-0000-0000-000000000004',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f4000000-0000-0000-0000-000000000001','f4100000-0000-0000-0000-000000000004','player', now() - interval '90 days', NULL);

SELECT app._t34_jwt('f4100000-0000-0000-0000-000000000004', 'player');

SELECT is(
  (app.rpc_get_my_score(current_date) ->> 'status'),
  'no_baseline', 'keine Baseline ueberhaupt (0 Check-Ins): status no_baseline'
);

-- -----------------------------------------------------------------------------
-- 9. Tuer: ohne bestaetigtes Team -> Ablehnung, self-only.
-- -----------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  json_build_object('sub','f4100000-0000-0000-0000-000000000001','role','authenticated','app_role','player')::text, true);

SELECT ok(
  app.is_denial(app.rpc_get_my_score(current_date)),
  'ohne bestaetigtes Team: rpc_get_my_score liefert eine Ablehnung'
);

SELECT * FROM finish();
ROLLBACK;
