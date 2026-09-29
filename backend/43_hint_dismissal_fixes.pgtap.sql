-- =============================================================================
-- 43_hint_dismissal_fixes.pgtap.sql — Gegenprobe zu Punkt 85
--
-- Fund 1: app.rpc_create_training_session/app.rpc_update_training_session
-- loeschen h2-Wegklicks ANDERER Einheiten desselben Tages, deren Tageslast
-- sich mitaendert. h1-Wegklicks (Negativkontrolle) bleiben von einer neuen
-- Einheit desselben Tages unberuehrt.
-- Fund 2: app._squad_check_v1 zaehlt einen h1-Wegklick nur noch am selben
-- Kalendertag, an dem ausgewertet wird. Ein Wegklick von "gestern" hebt sich
-- selbst wieder auf, ein Wegklick von "heute" gilt weiterhin.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(8);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4300000-0000-0000-0000-000000000001','Team C43','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('c4300000-0000-0000-0000-000000000002','c4300000-0000-0000-0000-000000000001','Coach C43',NULL,NULL,'c4300000-0000-0000-0000-000000000002',true),
  ('c4300000-0000-0000-0000-000000000011','c4300000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,NULL,true),
  ('c4300000-0000-0000-0000-000000000012','c4300000-0000-0000-0000-000000000001','P2 Markantname','abwehr',12,NULL,true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id WHEN 'c4300000-0000-0000-0000-000000000002' THEN 'coach' ELSE 'player' END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'c43%';

CREATE OR REPLACE FUNCTION app._t43_jwt(p_sub text, p_role text DEFAULT 'coach')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', 'c4300000-0000-0000-0000-000000000001')::text, true);
$$;

-- Ein Element aus dem jsonb-Array von app._squad_check_v1 nach person_id herausgreifen.
CREATE OR REPLACE FUNCTION app._t43_row(p_result jsonb, p_person text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT a FROM jsonb_array_elements(p_result) a WHERE a ->> 'person_id' = p_person;
$$;

-- -----------------------------------------------------------------------------
-- Fund 1: neue Einheit desselben Tages invalidiert h2 einer ANDEREN Einheit,
-- laesst h1 derselben Einheit unberuehrt (Negativkontrolle).
-- -----------------------------------------------------------------------------

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES ('c4300000-0000-0000-0000-0000000000a1', 'c4300000-0000-0000-0000-000000000001',
        current_date + 5, 60, 'field', 6);

INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version)
VALUES
  ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000a1',
   'c4300000-0000-0000-0000-000000000011','h2','v1'),
  ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000a1',
   'c4300000-0000-0000-0000-000000000011','h1','v1');

SELECT app._t43_jwt('c4300000-0000-0000-0000-000000000002');

-- Neue Einheit desselben Tages ueber die Tuer anlegen.
SELECT app.rpc_create_training_session(current_date + 5, NULL::time, 90::smallint, 'field'::app.app_session_type, 8::smallint, NULL::text);

SELECT is(
  (SELECT count(*)::int FROM app.session_hint_dismissals
    WHERE session_id = 'c4300000-0000-0000-0000-0000000000a1' AND hint_key = 'h2'),
  0,
  'Punkt 85 Fund 1: h2-Wegklick der ANDEREN Einheit desselben Tages wird durch eine neue Einheit geloescht'
);

SELECT is(
  (SELECT count(*)::int FROM app.session_hint_dismissals
    WHERE session_id = 'c4300000-0000-0000-0000-0000000000a1' AND hint_key = 'h1'),
  1,
  'Negativkontrolle: h1-Wegklick derselben Einheit bleibt unberuehrt (haengt nicht von anderen Einheiten ab)'
);

-- -----------------------------------------------------------------------------
-- Fund 1 (Update-Pfad): zwei Einheiten desselben Tages existieren schon (per
-- Fixture, nicht ueber die create-Tuer, um den obigen Effekt nicht erneut
-- auszuloesen). Aendern der Dauer der einen loescht h2 der anderen.
-- -----------------------------------------------------------------------------

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES
  ('c4300000-0000-0000-0000-0000000000b1', 'c4300000-0000-0000-0000-000000000001', current_date + 9, 60, 'field', 5),
  ('c4300000-0000-0000-0000-0000000000b2', 'c4300000-0000-0000-0000-000000000001', current_date + 9, 60, 'field', 5);

INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000b1',
        'c4300000-0000-0000-0000-000000000012','h2','v1');

SELECT app.rpc_update_training_session(
  'c4300000-0000-0000-0000-0000000000b2'::uuid, current_date + 9, NULL::time, 120::smallint, 'field'::app.app_session_type, 9::smallint, NULL::text
);

SELECT is(
  (SELECT count(*)::int FROM app.session_hint_dismissals
    WHERE session_id = 'c4300000-0000-0000-0000-0000000000b1' AND hint_key = 'h2'),
  0,
  'Punkt 85 Fund 1 (Update): h2-Wegklick der ANDEREN Einheit desselben Tages wird geloescht, wenn sich die Nachbareinheit aendert'
);

-- Kontrolle: eine Einheit an einem UNBETEILIGTEN Tag bleibt unberuehrt.
INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES ('c4300000-0000-0000-0000-0000000000c1', 'c4300000-0000-0000-0000-000000000001', current_date + 20, 60, 'field', 5);

INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000c1',
        'c4300000-0000-0000-0000-000000000012','h2','v1');

SELECT is(
  (SELECT count(*)::int FROM app.session_hint_dismissals
    WHERE session_id = 'c4300000-0000-0000-0000-0000000000c1' AND hint_key = 'h2'),
  1,
  'Negativkontrolle: h2-Wegklick einer Einheit an einem unbeteiligten Tag bleibt unberuehrt'
);

-- -----------------------------------------------------------------------------
-- Fund 2: h1-Wegklick von HEUTE zaehlt, h1-Wegklick von GESTERN nicht mehr.
-- -----------------------------------------------------------------------------

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES ('c4300000-0000-0000-0000-0000000000d1', 'c4300000-0000-0000-0000-000000000001', current_date + 3, 60, 'field', 4);

INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-000000000011',
        current_date, 3.0, 'low', '{}'::jsonb);

INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version, dismissed_at)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000d1',
        'c4300000-0000-0000-0000-000000000011','h1','v1', now());

SELECT ok(
  NOT (app._t43_row(app._squad_check_v1(
    'c4300000-0000-0000-0000-000000000001'::uuid, current_date + 3, 60::smallint, 4::smallint, 'c4300000-0000-0000-0000-0000000000d1'::uuid
  ), 'c4300000-0000-0000-0000-000000000011') -> 'hints') ? 'h1',
  'Punkt 85 Fund 2: ein HEUTE gemachter h1-Wegklick unterdrueckt den Hinweis weiterhin'
);

-- Wegklick auf "gestern" zuruecksetzen -- er bezieht sich auf einen ueberholten Tagesstand.
UPDATE app.session_hint_dismissals
   SET dismissed_at = now() - interval '1 day'
 WHERE session_id = 'c4300000-0000-0000-0000-0000000000d1' AND hint_key = 'h1';

SELECT ok(
  (app._t43_row(app._squad_check_v1(
    'c4300000-0000-0000-0000-000000000001'::uuid, current_date + 3, 60::smallint, 4::smallint, 'c4300000-0000-0000-0000-0000000000d1'::uuid
  ), 'c4300000-0000-0000-0000-000000000011') -> 'hints') ? 'h1',
  'Punkt 85 Fund 2: ein GESTERN gemachter h1-Wegklick zaehlt nicht mehr, der Hinweis erscheint wieder'
);

SELECT ok(
  NOT (app._t43_row(app._squad_check_v1(
    'c4300000-0000-0000-0000-000000000001'::uuid, current_date + 3, 60::smallint, 4::smallint, 'c4300000-0000-0000-0000-0000000000d1'::uuid
  ), 'c4300000-0000-0000-0000-000000000011') -> 'dismissed_hints') ? 'h1',
  'Punkt 85 Fund 2: der ueberholte Wegklick erscheint auch nicht mehr in dismissed_hints'
);

-- Negativkontrolle: h2 bleibt unbefristet gueltig (kein Tagesbezug wie h1/h4).
INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-000000000012',
        'session_load', current_date, 20, 100, 20, 'neutral', 'ok');

INSERT INTO app.session_hint_dismissals (team_id, session_id, person_id, hint_key, rule_version, dismissed_at)
VALUES ('c4300000-0000-0000-0000-000000000001','c4300000-0000-0000-0000-0000000000d1',
        'c4300000-0000-0000-0000-000000000012','h2','v1', now() - interval '3 days');

SELECT ok(
  NOT (app._t43_row(app._squad_check_v1(
    'c4300000-0000-0000-0000-000000000001'::uuid, current_date + 3, 60::smallint, 4::smallint, 'c4300000-0000-0000-0000-0000000000d1'::uuid
  ), 'c4300000-0000-0000-0000-000000000012') -> 'hints') ? 'h2',
  'Negativkontrolle: ein 3 Tage alter h2-Wegklick zaehlt weiterhin (h2 ist nicht tagesgebunden wie h1/h4)'
);

SELECT * FROM finish();
ROLLBACK;
