-- =============================================================================
-- 33_baseline_engine.pgtap.sql — Baseline-Engine (Bridge Punkt 57, Teil 1 von 3)
--
-- Prueft backend/33_baseline_engine.sql: Median/MAD-Statistik, sigma_floor,
-- n_obs<10 -> insufficient, Pause>14 Tage -> rebuilding, w_self bei n=5/n=20,
-- die Tuer (self-only, Ablehnung ohne Team), und dass ein Ausreisser den
-- Median robust laesst (Median/MAD statt Mittelwert/Standardabweichung).
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(15);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001','Team F1','Europe/Berlin');
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f1100000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','Spielerin F1','stuermerin','f1100000-0000-0000-0000-000000000001',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000001','player', now() - interval '90 days', NULL);

CREATE OR REPLACE FUNCTION app._t33_jwt(p_sub text, p_role text, p_team text DEFAULT 'f1000000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role, 'team_id', p_team)::text, true);
$$;

-- -----------------------------------------------------------------------------
-- 1. Konstante Reihe (28 Tage, immer 480 Minuten Schlaf) -> sigma = sigma_floor
-- -----------------------------------------------------------------------------
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000001',
       '2026-09-10'::date - g, 480, 4, 4, 4, 4, 4, 4, 4, 1
FROM generate_series(1,28) g;

SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000001','sleep_duration_min','2026-09-10');

SELECT is(
  (SELECT sigma FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000001' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  20.000::numeric(8,3),
  'konstante Reihe: sigma faellt auf sigma_floor (20 Minuten)'
);
SELECT is(
  (SELECT median FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000001' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  480.000::numeric(8,3),
  'konstante Reihe: Median = 480'
);
SELECT is(
  (SELECT status FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000001' AND metric='sleep_duration_min' AND as_of='2026-09-10')::text,
  'ok', 'konstante Reihe: status ok bei 28 Beobachtungen'
);

-- -----------------------------------------------------------------------------
-- 2. Ausreisser verschiebt den Median kaum (Robustheit gegen Mittelwert)
-- -----------------------------------------------------------------------------
UPDATE app.daily_checkins SET sleep_duration_min = 120
 WHERE person_id='f1100000-0000-0000-0000-000000000001' AND date = '2026-09-09';

SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000001','sleep_duration_min','2026-09-10');

SELECT cmp_ok(
  abs((SELECT median FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000001' AND metric='sleep_duration_min' AND as_of='2026-09-10') - 480.000),
  '<', 10.0,
  'ein Ausreisser (120 statt 480) verschiebt den Median um weniger als 10 Minuten (unter 2 Prozent)'
);

-- -----------------------------------------------------------------------------
-- 3. n_obs = 9 -> insufficient, keine Statistik
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f1100000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-000000000001','Spielerin F2','abwehr','f1100000-0000-0000-0000-000000000002',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000002','player', now() - interval '90 days', NULL);
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000002',
       '2026-09-10'::date - g, 450, 3, 3, 3, 3, 3, 3, 3, 0
FROM generate_series(1,9) g;

SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000002','sleep_duration_min','2026-09-10');

SELECT is(
  (SELECT status FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000002' AND metric='sleep_duration_min' AND as_of='2026-09-10')::text,
  'insufficient', 'n_obs=9 -> status insufficient'
);
SELECT is(
  (SELECT median FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000002' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  NULL::numeric(8,3), 'insufficient: keine Statistik geschrieben'
);

-- -----------------------------------------------------------------------------
-- 4. Pause > 14 Tage -> rebuilding, reset_at gesetzt
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f1100000-0000-0000-0000-000000000003','f1000000-0000-0000-0000-000000000001','Spielerin F3','abwehr','f1100000-0000-0000-0000-000000000003',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000003','player', now() - interval '90 days', NULL);
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000003',
       '2026-09-10'::date - (g + 15), 450, 3, 3, 3, 3, 3, 3, 3, 0
FROM generate_series(1,20) g;

SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000003','sleep_duration_min','2026-09-10');

SELECT is(
  (SELECT status FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000003' AND metric='sleep_duration_min' AND as_of='2026-09-10')::text,
  'rebuilding', 'letzte Beobachtung vor 16 Tagen -> status rebuilding'
);
SELECT isnt(
  (SELECT reset_at FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000003' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  NULL, 'rebuilding: reset_at gesetzt'
);

-- -----------------------------------------------------------------------------
-- 5. w_self: n=5 -> 0, n=20 -> 1
-- -----------------------------------------------------------------------------
INSERT INTO app.persons (id, team_id, display_name, person_position, auth_user_id, is_active) VALUES
  ('f1100000-0000-0000-0000-000000000004','f1000000-0000-0000-0000-000000000001','Spielerin F4','abwehr','f1100000-0000-0000-0000-000000000004',true),
  ('f1100000-0000-0000-0000-000000000005','f1000000-0000-0000-0000-000000000001','Spielerin F5','abwehr','f1100000-0000-0000-0000-000000000005',true);
INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to) VALUES
  ('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000004','player', now() - interval '90 days', NULL),
  ('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000005','player', now() - interval '90 days', NULL);
-- F4: 5 Tage vor -1 (also n=5, damit n<10 -> eigentlich insufficient. Fuer w_self=0
-- pruefen wir daher direkt an F2 (n_obs=9, siehe oben) analog: w_self dort ist
-- ohnehin 1.000 (Default im insufficient-Zweig). Stattdessen: 10 Beobachtungen fuer
-- w_self-Nachweis bei kleinem n (>=10, damit die Formel ueberhaupt greift).
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000004',
       '2026-09-10'::date - g, 450, 3, 3, 3, 3, 3, 3, 3, 0
FROM generate_series(1,10) g;
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_duration_min, sleep_quality, recovery, energy, mental_stress, mental_mood, mental_motivation, training_readiness, pain_max)
SELECT 'f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000005',
       '2026-09-10'::date - g, 450, 3, 3, 3, 3, 3, 3, 3, 0
FROM generate_series(1,25) g;

SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000004','sleep_duration_min','2026-09-10');
SELECT app._compute_baseline('f1000000-0000-0000-0000-000000000001','f1100000-0000-0000-0000-000000000005','sleep_duration_min','2026-09-10');

SELECT is(
  (SELECT w_self FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000004' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  0.333::numeric(4,3), 'n_obs=10: w_self = (10-5)/15 = 0.333'
);
SELECT is(
  (SELECT w_self FROM app.baselines WHERE person_id='f1100000-0000-0000-0000-000000000005' AND metric='sleep_duration_min' AND as_of='2026-09-10'),
  1.000::numeric(4,3), 'n_obs=25 (>=20): w_self = 1.000'
);

-- -----------------------------------------------------------------------------
-- 6. Tuer: ohne bestaetigtes Team -> Ablehnung, keine Zeile
-- -----------------------------------------------------------------------------
SELECT app._t33_jwt('f1100000-0000-0000-0000-000000000001', 'player');
-- Rolle ist gueltig, aber KEIN team_id Claim gesetzt -> auth_team_id() NULL.
SELECT set_config('request.jwt.claims',
  json_build_object('sub','f1100000-0000-0000-0000-000000000001','role','authenticated','app_role','player')::text, true);

SELECT ok(
  app.is_denial(app.rpc_get_my_baselines('2026-09-10')),
  'ohne bestaetigtes Team: rpc_get_my_baselines liefert eine Ablehnung'
);

-- -----------------------------------------------------------------------------
-- 7. Tuer: self liest eigene Baselines, 11 Metriken, konstante Metrik korrekt
-- -----------------------------------------------------------------------------
SELECT app._t33_jwt('f1100000-0000-0000-0000-000000000001', 'player');

SELECT is(
  jsonb_array_length(app.rpc_get_my_baselines('2026-09-10')),
  11, 'self erhaelt alle 11 Metriken (Rest on-the-fly berechnet)'
);

SELECT is(
  (
    SELECT (x ->> 'median')::numeric
    FROM jsonb_array_elements(app.rpc_get_my_baselines('2026-09-10')) x
    WHERE x ->> 'metric' = 'sleep_duration_min'
  ),
  480.000::numeric,
  'Tuer liefert denselben Median wie die direkte Tabellenpruefung'
);

SELECT is(
  (
    SELECT jsonb_array_length(x -> 'raw_series')
    FROM jsonb_array_elements(app.rpc_get_my_baselines('2026-09-10')) x
    WHERE x ->> 'metric' = 'sleep_duration_min'
  ),
  28, 'raw_series traegt alle 28 Tage des Fensters'
);

-- -----------------------------------------------------------------------------
-- 8. Fremde Person sieht NICHT die Baseline einer anderen (self-only)
-- -----------------------------------------------------------------------------
SELECT app._t33_jwt('f1100000-0000-0000-0000-000000000002', 'player');
SELECT isnt(
  (
    SELECT (x ->> 'n_obs')::int
    FROM jsonb_array_elements(app.rpc_get_my_baselines('2026-09-10')) x
    WHERE x ->> 'metric' = 'sleep_duration_min'
  ),
  28, 'Person F2 (eigene Historie n=9) sieht NICHT die 28 Beobachtungen von F1'
);

SELECT * FROM finish();
ROLLBACK;
