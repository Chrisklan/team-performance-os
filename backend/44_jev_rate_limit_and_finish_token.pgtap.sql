-- =============================================================================
-- 44_jev_rate_limit_and_finish_token.pgtap.sql — Gegenprobe zu Punkt 86/87
--
-- Punkt 86 (Nachtrag 2026-09-29, zaehlbasierte Drosselung statt Hash-exakt):
--   - ohne/mit falschem p_context_secret lehnt die Tuer komplett ab, BEVOR
--     irgendeine Zeile entsteht (Punkt 87 Nachtrag, siehe unten).
--   - der erste Aufruf legt eine pending-Zeile an.
--   - trotz UNTERSCHIEDLICHER p_duration_min je Aufruf (Root-Fix: die Tuer
--     liest duration_min/planned_intensity jetzt aus der gespeicherten
--     Session, der Client-Wert wird ignoriert) greift die Drosselung ab dem
--     sechsten Aufruf derselben Person im selben Team innerhalb von 5 Minuten
--     -- eine Gegenprobe zur alten, per Hash trivial umgehbaren Fassung.
--   - die zurueckgegebene session.duration_min entspricht der GESPEICHERTEN
--     Session (60), nicht dem manipulierten Client-Wert (999) -- Beleg fuer
--     den Root-Fix von Punkt 86a.
--   - eine ANDERE Person im selben Team (coach2) ist von coach1's Drosselung
--     unberuehrt -- Beleg fuer den Fix von Punkt 86c (Drosselung war
--     team-weit statt personenbezogen).
--   - ausserhalb des 5-Minuten-Fensters (occurred_at zurueckdatiert) ist
--     coach1 wieder erlaubt.
-- Punkt 87 (Nachtrag 2026-09-29, Server-Secret gegen Phantom-Zeilen):
--   - app.rpc_squad_check_jev_context ohne/mit falschem p_context_secret ->
--     deny (42501), mit korrektem Secret wie zuvor.
--   - app.rpc_finish_model_call verlangt weiterhin das korrekte finish_token.
--     Ein falsches oder fehlendes Token -> deny (42501), das korrekte Token
--     schliesst die Zeile ab wie zuvor.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(10);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4400000-0000-0000-0000-000000000001','Team C44','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('c4400000-0000-0000-0000-000000000002','c4400000-0000-0000-0000-000000000001','Coach C44',NULL,NULL,'c4400000-0000-0000-0000-000000000002',true),
  ('c4400000-0000-0000-0000-000000000003','c4400000-0000-0000-0000-000000000001','Coach2 C44',NULL,NULL,'c4400000-0000-0000-0000-000000000003',true),
  ('c4400000-0000-0000-0000-000000000005','c4400000-0000-0000-0000-000000000001','Admin C44',NULL,NULL,'c4400000-0000-0000-0000-000000000005',true),
  ('c4400000-0000-0000-0000-000000000011','c4400000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,NULL,true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id WHEN 'c4400000-0000-0000-0000-000000000002' THEN 'coach'
                 WHEN 'c4400000-0000-0000-0000-000000000003' THEN 'coach'
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

-- Punkt 87 Nachtrag: Server-Secret hinterlegen (Ops-Setup, ausserhalb des
-- Anfragepfads -- app.rpc_set_jev_context_secret laeuft hier als Superuser,
-- genau wie das Setup-Skript, das es in der Cloud per service_role aufruft).
SELECT app.rpc_set_jev_context_secret('t44-test-secret-mindestens-20-zeichen');

SELECT app._t44_jwt('c4400000-0000-0000-0000-000000000002', 'coach');

-- -----------------------------------------------------------------------------
-- Punkt 87 Nachtrag: ohne/mit falschem Secret lehnt die Tuer komplett ab,
-- BEVOR irgendeine Zeile entsteht.
-- -----------------------------------------------------------------------------

SELECT is(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint, NULL
  ) ->> 'code'),
  '42501',
  'Punkt 87 Nachtrag: fehlendes p_context_secret wird abgelehnt (deny), bevor eine Zeile entsteht'
);

SELECT is(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint, 'falsches-secret-mindestens-20-zeichen'
  ) ->> 'code'),
  '42501',
  'Punkt 87 Nachtrag: falsches p_context_secret wird abgelehnt (deny)'
);

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'c4400000-0000-0000-0000-000000000001'),
  0,
  'Punkt 87 Nachtrag: die zwei abgelehnten Aufrufe oben haben KEINE Zeile in model_call_log angelegt'
);

-- -----------------------------------------------------------------------------
-- Punkt 86: mit korrektem Secret legt der erste Aufruf eine pending-Zeile an.
-- Root-Fix (Punkt 86a): p_duration_min=999 ist frei erfunden (Client-Wert) --
-- die Tuer muss trotzdem die GESPEICHERTE Session (60) verwenden.
-- -----------------------------------------------------------------------------

SELECT ok(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 999::smallint, 1::smallint,
    't44-test-secret-mindestens-20-zeichen'
  ) -> 'session' ->> 'duration_min') = '60',
  'Punkt 86 Root-Fix: session.duration_min in der Antwort ist die GESPEICHERTE Session (60), '
  'nicht der manipulierte Client-Wert (999) oder die manipulierte Intensitaet'
);

-- Vier weitere Aufrufe derselben Person (insgesamt fuenf, c_rate_limit_max_calls),
-- jeweils mit einem ANDEREN erfundenen p_duration_min -- waere die Drosselung
-- noch Hash-basiert, wuerde jede Variation einen neuen, unbegrenzten Aufruf
-- erlauben (das war genau Punkt 86a). Zaehlbasiert zaehlen alle fuenf mit.
SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 111::smallint, 2::smallint, 't44-test-secret-mindestens-20-zeichen');
SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 222::smallint, 3::smallint, 't44-test-secret-mindestens-20-zeichen');
SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 333::smallint, 4::smallint, 't44-test-secret-mindestens-20-zeichen');
SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 444::smallint, 5::smallint, 't44-test-secret-mindestens-20-zeichen');

SELECT throws_ok(
  $$ SELECT app.rpc_squad_check_jev_context('c4400000-0000-0000-0000-0000000000a1'::uuid, 555::smallint, 6::smallint, 't44-test-secret-mindestens-20-zeichen') $$,
  '55000',
  NULL,
  'Punkt 86 (Nachtrag, zaehlbasiert): der sechste Aufruf derselben Person im selben Team '
  'innerhalb von 5 Minuten wird mit RATE_LIMITED (55000) abgelehnt, trotz abweichender '
  'p_duration_min je Aufruf'
);

-- -----------------------------------------------------------------------------
-- Punkt 86c: eine ANDERE Person (coach2) im selben Team ist von coach1's
-- Drosselung unberuehrt -- die alte, team-weite Fassung haette hier ebenfalls
-- RATE_LIMITED geworfen.
-- -----------------------------------------------------------------------------

SELECT app._t44_jwt('c4400000-0000-0000-0000-000000000003', 'coach');

SELECT isnt(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
    't44-test-secret-mindestens-20-zeichen'
  ) ->> 'call_id'),
  NULL,
  'Punkt 86c: eine ANDERE Person (coach2) im selben Team ist von coach1''s Drosselung unberuehrt'
);

-- Ausserhalb des 5-Minuten-Fensters (occurred_at zurueckdatiert) ist coach1
-- wieder erlaubt.
SELECT app._t44_jwt('c4400000-0000-0000-0000-000000000002', 'coach');

UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes'
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001';

SELECT isnt(
  (app.rpc_squad_check_jev_context(
    'c4400000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
    't44-test-secret-mindestens-20-zeichen'
  ) ->> 'call_id'),
  NULL,
  'Punkt 86: nach Ablauf des 5-Minuten-Fensters ist coach1 wieder erlaubt'
);

-- -----------------------------------------------------------------------------
-- Punkt 87: finish_token wird verlangt.
-- -----------------------------------------------------------------------------

UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes'
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001';

SELECT app.rpc_squad_check_jev_context(
  'c4400000-0000-0000-0000-0000000000a1'::uuid, 61::smallint, 6::smallint,
  't44-test-secret-mindestens-20-zeichen'
);

SELECT id, finish_token INTO TEMP TABLE t44_last_call
  FROM app.model_call_log
 WHERE team_id = 'c4400000-0000-0000-0000-000000000001'
   AND actor_id = 'c4400000-0000-0000-0000-000000000002'
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
