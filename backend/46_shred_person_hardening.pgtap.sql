-- =============================================================================
-- 46_shred_person_hardening.pgtap.sql — Gegenprobe zu Punkt 89, 91, 92
--
-- Punkt 89: nach rpc_shred_person sind shirt_number/person_position/
-- position_cluster NULL (Quasi-Identifikatoren), created_at bleibt bewusst
-- stehen (siehe Kopfkommentar der Migration).
-- Punkt 91: rpc_rebuild_baseline_history lehnt eine geschredderte
-- (is_active=false) Zielperson ab.
-- Punkt 92: die sechs DELETEs aus Punkt 84/92 raeumen eine Zeile mit einer
-- ANDEREN team_id auf (simulierter Teamwechsel), die aelteren DELETEs
-- (z.B. daily_checkins) tun das weiterhin NICHT -- Kontrolle, dass nur die
-- sechs genannten Tabellen geaendert wurden.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(8);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4600000-0000-0000-0000-000000000001','Team C46','Europe/Berlin'),
  ('c4600000-0000-0000-0000-000000000002','Team C46b (fremd/alt)','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, position_cluster, auth_user_id, is_active) VALUES
  ('c4600000-0000-0000-0000-000000000005','c4600000-0000-0000-0000-000000000001','Admin C46',NULL,NULL,NULL,'c4600000-0000-0000-0000-000000000005',true),
  ('c4600000-0000-0000-0000-000000000011','c4600000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,'offense','c4600000-0000-0000-0000-000000000011',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id, CASE p.id WHEN 'c4600000-0000-0000-0000-000000000005' THEN 'admin' ELSE 'player' END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'c46%';

-- Punkt 92: Zeilen mit einer ANDEREN team_id als p1's aktuelle -- simuliert
-- den (heute technisch nicht moeglichen) Teamwechsel, den Punkt 92 beschreibt.
INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status)
VALUES ('c4600000-0000-0000-0000-000000000002','c4600000-0000-0000-0000-000000000011',
        'session_load', current_date, 20, 100, 20, 'neutral', 'ok');
WITH ts AS (
  INSERT INTO app.training_sessions (team_id, session_date, duration_min, session_type, planned_intensity)
  VALUES ('c4600000-0000-0000-0000-000000000002', current_date, 60, 'field', 5)
  RETURNING id
)
INSERT INTO app.session_rpe (team_id, person_id, session_id, rpe, duration_min)
SELECT 'c4600000-0000-0000-0000-000000000002', 'c4600000-0000-0000-0000-000000000011', id, 5, 60 FROM ts;

-- Kontrolle: eine aeltere Tabelle (daily_checkins) mit derselben "fremden"
-- team_id -- muss NACH dem Shred stehen bleiben (Punkt 92 aendert sie nicht).
INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at, checkin_submitted_at)
VALUES ('c4600000-0000-0000-0000-000000000002','c4600000-0000-0000-0000-000000000011', current_date - 30, 4, now(), now());

CREATE OR REPLACE FUNCTION app._t46_jwt(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', 'c4600000-0000-0000-0000-000000000001')::text, true);
$$;

SELECT app._t46_jwt('c4600000-0000-0000-0000-000000000005', 'admin');

-- -----------------------------------------------------------------------------
-- Punkt 91: VOR dem Shred ist der Rebuild erlaubt (Kontrolle).
-- -----------------------------------------------------------------------------

SELECT ok(
  NOT ((app.rpc_rebuild_baseline_history(
    'c4600000-0000-0000-0000-000000000011'::uuid, current_date - 2, current_date
  )) ? 'code'),
  'Kontrolle: Rebuild ist fuer eine aktive Person erlaubt (kein deny)'
);

-- Shred ausfuehren.
SELECT app.rpc_shred_person('c4600000-0000-0000-0000-000000000011'::uuid);

-- -----------------------------------------------------------------------------
-- Punkt 89: shirt_number/person_position/position_cluster NULL, created_at
-- unveraendert.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT shirt_number FROM app.persons WHERE id = 'c4600000-0000-0000-0000-000000000011'),
  NULL::smallint,
  'Punkt 89: shirt_number ist nach dem Shred NULL'
);

SELECT is(
  (SELECT person_position FROM app.persons WHERE id = 'c4600000-0000-0000-0000-000000000011'),
  NULL::text,
  'Punkt 89: person_position ist nach dem Shred NULL'
);

SELECT is(
  (SELECT position_cluster FROM app.persons WHERE id = 'c4600000-0000-0000-0000-000000000011'),
  NULL::text,
  'Punkt 89: position_cluster ist nach dem Shred NULL'
);

SELECT ok(
  (SELECT created_at FROM app.persons WHERE id = 'c4600000-0000-0000-0000-000000000011') IS NOT NULL,
  'Punkt 89: created_at bleibt bewusst stehen (Begruendung im Migrationskommentar)'
);

-- -----------------------------------------------------------------------------
-- Punkt 91: NACH dem Shred (is_active=false) lehnt die Tuer einen Rebuild ab.
-- -----------------------------------------------------------------------------

SELECT ok(
  (app.rpc_rebuild_baseline_history(
    'c4600000-0000-0000-0000-000000000011'::uuid, current_date - 2, current_date
  ) ->> 'code') = '42501',
  'Punkt 91: Rebuild fuer eine geschredderte (is_active=false) Person wird abgelehnt'
);

-- -----------------------------------------------------------------------------
-- Punkt 92: die sechs DELETEs raeumen auch eine Zeile mit einer ANDEREN
-- team_id auf, die aeltere daily_checkins-Zeile mit derselben fremden
-- team_id bleibt unberuehrt (kein team_id-Filter-Fix ausserhalb der sechs).
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.baselines WHERE person_id = 'c4600000-0000-0000-0000-000000000011'),
  0,
  'Punkt 92: app.baselines-Zeile mit ABWEICHENDER team_id wird trotzdem geloescht (nur person_id-Filter)'
);

SELECT is(
  (SELECT count(*)::int FROM app.daily_checkins WHERE person_id = 'c4600000-0000-0000-0000-000000000011'),
  1,
  'Kontrolle: die AELTERE daily_checkins-Zeile mit abweichender team_id bleibt stehen (nicht Teil von Punkt 92)'
);

SELECT * FROM finish();
ROLLBACK;
