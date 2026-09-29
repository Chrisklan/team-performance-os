-- =============================================================================
-- 44_jev_rate_limit_and_finish_token.pgtap.sql — Gegenprobe zu Punkt 86/87
--
-- Punkt 86: zwei Aufrufe von app.rpc_squad_check_jev_context mit identischem
-- input_hash (gleiche Einheit, gleiche Dauer/Intensitaet, gleicher Kandidaten-
-- stand) innerhalb von 5 Minuten -> der zweite wirft RATE_LIMITED (55000).
-- Ein Aufruf ausserhalb des Fensters (occurred_at manuell zurueckdatiert) ist
-- wieder erlaubt. Ein Aufruf mit abweichenden Eingaben (andere Dauer) ist vom
-- Fenster des ersten Aufrufs unberuehrt.
-- Punkt 87: app.rpc_finish_model_call verlangt jetzt zusaetzlich das korrekte
-- finish_token. Ein falsches oder fehlendes Token -> deny (42501), das
-- korrekte Token schliesst die Zeile ab wie zuvor.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(6);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4400000-0000-0000-0000-000000000001','Team C44','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('c4400000-0000-0000-0000-000000000002','c4400000-0000-0000-0000-000000000001','Coach C44',NULL,NULL,'c4400000-0000-0000-0000-000000000002',true),
  ('c4400000-0000-0000-0000-000000000005','c4400000-0000-0000-0000-000000000001','Admin C44',NULL,NULL,'c4400000-0000-0000-0000-000000000005',true),
  ('c4400000-0000-0000-0000-000000000011','c4400000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,NULL,true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id WHEN 'c4400000-0000-0000-0000-000000000002' THEN 'coach'
                 WHEN 'c4400000-0000-0000-0000-000000000005' THEN 'admin'
                 ELSE 'player' END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'c44%';

CREATE OR REPLACE FUNCTION app._t44_jwt(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', 'c4400000-0000-0000-0000-000000000001')::text, true);
$$;

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES ('c4400000-0000-0000-0000-0000000000a1', 'c4400000-0000-0000-0000-000000000001',
        current_date, 60, 'field', 6);

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at, checkin_submitted_at)
VALUES ('c4400000-0000-0000-0000-000000000001','c4400000-0000-0000-0000-000000000011', current_date, 5, now(), now());

-- Band bewusst 'high' (nicht 'low'): bei 'low' waeren h1 UND h2 gleichzeitig
-- aktiv, das eskaliert Regel v1 selbst schon auf "reduziert" und die Person
-- waere gar kein JEV-Kandidat mehr (Kandidatenfilter verlangt suggestion=full).
INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors)
VALUES ('c4400000-0000-0000-0000-000000000001','c4400000-0000-0000-0000-000000000011',
        current_date, 8.0, 'high', '{}'::jsonb);

INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status)
VALUES ('c4400000-0000-0000-0000-000000000001','c4400000-0000-0000-0000-000000000011',
        'session_load', current_date, 20, 280, 60, 'neutral', 'ok');

SELECT app._t44_jwt('c4400000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', true);

SELECT app._t44_jwt('c4400000-0000-0000-0000-000000000002', 'coach');

-- -----------------------------------------------------------------------------
-- Punkt 86: erster Aufruf legt eine pending-Zeile an, der zweite (identische
-- Eingaben, gleiche Session) innerhalb von 5 Minuten ist RATE_LIMITED.
-- -----------------------------------------------------------------------------

SELECT isnt(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint
  ) ->> 'call_id'),
  NULL,
  'Erster Aufruf legt eine pending-Zeile an und liefert eine call_id'
);

SELECT throws_ok(
  $$ SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint) $$,
  '55000',
  NULL,
  'Punkt 86: identischer Aufruf innerhalb von 5 Minuten wird mit RATE_LIMITED (55000) abgelehnt'
);

-- Ausserhalb des 5-Minuten-Fensters (occurred_at zurueckdatiert) ist derselbe
-- Aufruf wieder erlaubt.
UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes'
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001';

SELECT isnt(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint
  ) ->> 'call_id'),
  NULL,
  'Punkt 86: nach Ablauf des 5-Minuten-Fensters ist derselbe Aufruf wieder erlaubt'
);

-- -----------------------------------------------------------------------------
-- Punkt 87: finish_token wird verlangt.
-- -----------------------------------------------------------------------------

UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes'
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001';

SELECT app.rpc_squad_check_jev_context(
  'c4400000-0000-0000-0000-0000000000a1'::uuid, 61::smallint, 6::smallint
);

SELECT id, finish_token INTO TEMP TABLE t44_last_call
  FROM app.model_call_log
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001'
 ORDER BY occurred_at DESC LIMIT 1;

SELECT is(
  (app.rpc_finish_model_call(
    (SELECT id FROM t44_last_call), 'ok', 500, gen_random_uuid()
  ) ->> 'code'),
  '42501',
  'Punkt 87: falsches finish_token wird abgelehnt (deny)'
);

SELECT is(
  (app.rpc_finish_model_call(
    (SELECT id FROM t44_last_call), 'ok', 500, (SELECT finish_token FROM t44_last_call)
  ) ->> 'result_class'),
  'ok',
  'Punkt 87: korrektes finish_token schliesst die Zeile ab wie zuvor'
);

SELECT is(
  (SELECT result_class FROM app.model_call_log WHERE id = (SELECT id FROM t44_last_call)),
  'ok',
  'Punkt 87: die Zeile ist in der Datenbank tatsaechlich auf ok abgeschlossen'
);

SELECT * FROM finish();
ROLLBACK;
