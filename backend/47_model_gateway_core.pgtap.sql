-- =============================================================================
-- 47_model_gateway_core.pgtap.sql — Gegenprobe zum KI-Gateway-Kern (AP-70a)
--
-- Deckt ab:
--   - app._mg_purpose_config/_mg_secret_ok/_mg_throttle/_mg_open sind fuer
--     authenticated/anon nicht ausfuehrbar (REVOKE, has_function_privilege).
--   - Konfiguration ist festgeschrieben: ap69_squad_check liefert die
--     bisherigen AP-69-Werte, ein unbekannter Zweck liefert NULL.
--   - Alte (app.rpc_set_jev_context_secret/app._jev_context_secret_ok) und
--     neue (app.rpc_set_model_gateway_secret/app._mg_secret_ok) Secret-
--     Funktionen sind aequivalent (Wrapper-Test, beide Richtungen).
--   - Drosselung ist je Zweck isoliert: ein fuer 'ap69_squad_check'
--     ausgeschoepfter Zaehler blockiert einen anderen (test-lokal
--     eingefuehrten) Zweck fuer dieselbe Person/Team nicht. Die
--     Konfiguration wird dafuer innerhalb der Transaktion (rollt zurueck) um
--     einen zweiten Test-Zweck erweitert -- ausserhalb des Tests bleibt nur
--     ap69_squad_check bekannt.
--   - 'rejected' ist ueber app.rpc_finish_model_call abschliessbar, ein
--     unbekannter result_class liefert weiterhin 22023 (unveraendertes
--     Verhalten).
--   - app._mg_open/_mg_throttle schreiben nicht in readiness_scores,
--     medical_clearances, daily_checkins (T2-artig).
--   - End-to-End: app.rpc_squad_check_jev_context liefert weiterhin
--     candidates/refs und legt die pending-Zeile mit provider/model/
--     rule_version aus der Konfiguration an (Verhaltenserhalt gegenueber 44).
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(53);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4700000-0000-0000-0000-000000000001','Team C47','Europe/Berlin'),
  ('c4700000-0000-0000-0000-00000000ffff','Team C47-Fremd','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('c4700000-0000-0000-0000-000000000002','c4700000-0000-0000-0000-000000000001','Coach C47',NULL,NULL,'c4700000-0000-0000-0000-000000000002',true),
  ('c4700000-0000-0000-0000-000000000005','c4700000-0000-0000-0000-000000000001','Admin C47',NULL,NULL,'c4700000-0000-0000-0000-000000000005',true),
  ('c4700000-0000-0000-0000-000000000011','c4700000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,NULL,true),
  ('c4700000-0000-0000-0000-00000000ff11','c4700000-0000-0000-0000-00000000ffff','P-Fremd Markantname','sturm',12,NULL,true),
  -- L4 (Fixrunde): physio/doctor fuer den Rollenablehnungs-Test an der Tuer.
  ('c4700000-0000-0000-0000-000000000006','c4700000-0000-0000-0000-000000000001','Physio C47',NULL,NULL,'c4700000-0000-0000-0000-000000000006',true),
  ('c4700000-0000-0000-0000-000000000007','c4700000-0000-0000-0000-000000000001','Doctor C47',NULL,NULL,'c4700000-0000-0000-0000-000000000007',true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id WHEN 'c4700000-0000-0000-0000-000000000002' THEN 'coach'
                 WHEN 'c4700000-0000-0000-0000-000000000005' THEN 'admin'
                 WHEN 'c4700000-0000-0000-0000-000000000006' THEN 'physio'
                 WHEN 'c4700000-0000-0000-0000-000000000007' THEN 'doctor'
                 ELSE 'player' END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'c4700000-0000-0000-0000-0000000000%';

CREATE OR REPLACE FUNCTION app._t47_jwt(p_sub text, p_role text, p_team text DEFAULT 'c4700000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', p_team)::text, true);
$$;

INSERT INTO app.training_sessions (id, team_id, session_date, duration_min, session_type, planned_intensity)
VALUES ('c4700000-0000-0000-0000-0000000000a1', 'c4700000-0000-0000-0000-000000000001',
        current_date, 60, 'field', 6);

INSERT INTO app.daily_checkins (team_id, person_id, date, sleep_quality, submitted_at, checkin_submitted_at)
VALUES ('c4700000-0000-0000-0000-000000000001','c4700000-0000-0000-0000-000000000011', current_date, 5, now(), now());

-- band 'high' (nicht 'low'): sonst eskaliert Regel v1 selbst schon auf
-- "reduziert", die Person waere kein JEV-Kandidat mehr.
INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors)
VALUES ('c4700000-0000-0000-0000-000000000001','c4700000-0000-0000-0000-000000000011',
        current_date, 8.0, 'high', '{}'::jsonb);

INSERT INTO app.baselines (team_id, person_id, metric, as_of, n_obs, median, sigma, direction, status)
VALUES ('c4700000-0000-0000-0000-000000000001','c4700000-0000-0000-0000-000000000011',
        'session_load', current_date, 20, 280, 60, 'neutral', 'ok');

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', true);
SELECT app.rpc_set_jev_context_secret('t47-test-secret-mindestens-20-zeichen');

-- -----------------------------------------------------------------------------
-- 1. REVOKE: die _mg_*-Helfer sind fuer authenticated/anon nicht ausfuehrbar.
-- -----------------------------------------------------------------------------

SELECT ok(
  NOT has_function_privilege('authenticated', 'app._mg_purpose_config(text)', 'EXECUTE'),
  'app._mg_purpose_config: kein EXECUTE fuer authenticated'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app._mg_purpose_config(text)', 'EXECUTE'),
  'app._mg_purpose_config: kein EXECUTE fuer anon'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app._mg_secret_ok(text)', 'EXECUTE'),
  'app._mg_secret_ok: kein EXECUTE fuer authenticated'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app._mg_throttle(text, text)', 'EXECUTE'),
  'app._mg_throttle: kein EXECUTE fuer authenticated'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'app._mg_open(text, uuid, text, uuid[], text)', 'EXECUTE'),
  'app._mg_open: kein EXECUTE fuer authenticated'
);

-- -----------------------------------------------------------------------------
-- 2. Konfiguration ist festgeschrieben.
-- -----------------------------------------------------------------------------

SELECT is(
  app._mg_purpose_config('ap69_squad_check'),
  jsonb_build_object(
    'provider', 'openrouter', 'model', 'typesafe/jev-1.13', 'rule_version', 'v1',
    'flag', 'jev_squad_check_enabled', 'rate_max', 5, 'rate_window', '5 minutes',
    'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
    'allow_empty_subjects', true
  ),
  'app._mg_purpose_config(''ap69_squad_check''): exakt die bisherigen AP-69-Werte plus allow_empty_subjects (F3-Fix)'
);

SELECT is(
  app._mg_purpose_config('ap99_unknown'),
  NULL::jsonb,
  'app._mg_purpose_config: unbekannter Zweck liefert NULL'
);

-- -----------------------------------------------------------------------------
-- 3. Alte und neue Secret-Funktionen sind aequivalent.
-- -----------------------------------------------------------------------------

SELECT ok(
  app._mg_secret_ok('t47-test-secret-mindestens-20-zeichen'),
  'app._mg_secret_ok: erkennt das ueber den alten Wrapper (rpc_set_jev_context_secret) gesetzte Secret'
);
SELECT ok(
  app._jev_context_secret_ok('t47-test-secret-mindestens-20-zeichen'),
  'app._jev_context_secret_ok (Wrapper): erkennt dasselbe Secret'
);
SELECT ok(
  NOT app._mg_secret_ok('falsches-secret-mindestens-20-zeichen'),
  'app._mg_secret_ok: falsches Secret wird abgelehnt'
);

SELECT app.rpc_set_model_gateway_secret('t47-zweites-secret-mindestens-20-zeichen');

SELECT ok(
  app._jev_context_secret_ok('t47-zweites-secret-mindestens-20-zeichen'),
  'app._jev_context_secret_ok (Wrapper): erkennt ein ueber die NEUE Funktion gesetztes Secret'
);
SELECT ok(
  NOT app._mg_secret_ok('t47-test-secret-mindestens-20-zeichen'),
  'app._mg_secret_ok: das alte Secret gilt nach dem Ueberschreiben nicht mehr (Singleton)'
);

SELECT app.rpc_set_jev_context_secret('t47-test-secret-mindestens-20-zeichen');

SELECT is(
  to_regclass('app.jev_context_secret'),
  NULL::regclass,
  'app.jev_context_secret ist entfernt, app.model_gateway_secret ist die einzige Quelle'
);

-- -----------------------------------------------------------------------------
-- 4. Drosselung ist je Zweck isoliert (test-lokale Erweiterung der Konfiguration,
--    rollt mit der Transaktion zurueck).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app._mg_purpose_config(p_purpose text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = app, pg_temp AS $$
  SELECT CASE p_purpose
    WHEN 'ap69_squad_check' THEN jsonb_build_object(
      'provider', 'openrouter', 'model', 'typesafe/jev-1.13', 'rule_version', 'v1',
      'flag', 'jev_squad_check_enabled', 'rate_max', 5, 'rate_window', '5 minutes',
      'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
      'allow_empty_subjects', true
    )
    WHEN 'c47_test_other' THEN jsonb_build_object(
      'provider', 'openrouter', 'model', 'typesafe/jev-1.13', 'rule_version', 'v1',
      'flag', 'jev_squad_check_enabled', 'rate_max', 5, 'rate_window', '5 minutes',
      'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
      'allow_empty_subjects', true
    )
    ELSE NULL
  END;
$$;

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

-- 5 Aufrufe schoepfen den Zaehler fuer ap69_squad_check aus (c_rate_limit_max_calls).
SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle');
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h1', 0);
SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle');
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h2', 0);
SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle');
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h3', 0);
SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle');
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h4', 0);
SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle');
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h5', 0);

SELECT throws_ok(
  $$ SELECT app._mg_throttle('ap69_squad_check', 'c47.throttle') $$,
  '55000',
  NULL,
  'app._mg_throttle: der sechste Aufruf fuer ap69_squad_check wird RATE_LIMITED'
);

SELECT lives_ok(
  $$ SELECT app._mg_throttle('c47_test_other', 'c47.throttle.other') $$,
  'app._mg_throttle: ein ANDERER Zweck (test-lokal) ist von der Ausschoepfung von ap69_squad_check unberuehrt'
);

-- -----------------------------------------------------------------------------
-- 5. rpc_finish_model_call: 'rejected' ist abschliessbar, ein unbekannter Wert
--    liefert weiterhin 22023.
-- -----------------------------------------------------------------------------

WITH ins AS (
  INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
  VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h-rejected', 0)
  RETURNING id, finish_token
)
SELECT id, finish_token INTO TEMP TABLE t47_rejected_call FROM ins;

SELECT is(
  (app.rpc_finish_model_call((SELECT id FROM t47_rejected_call), 'rejected', 12, (SELECT finish_token FROM t47_rejected_call)) ->> 'result_class'),
  'rejected',
  'app.rpc_finish_model_call: result_class ''rejected'' wird angenommen (Ausgangswaechter AP-70b)'
);
SELECT is(
  (SELECT result_class FROM app.model_call_log WHERE id = (SELECT id FROM t47_rejected_call)),
  'rejected',
  'app.rpc_finish_model_call: die Zeile ist tatsaechlich auf rejected abgeschlossen'
);

WITH ins AS (
  INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
  VALUES ('c4700000-0000-0000-0000-000000000001', 'ap69_squad_check', 'person', 'c4700000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h-great', 0)
  RETURNING id, finish_token
)
SELECT id, finish_token INTO TEMP TABLE t47_great_call FROM ins;

SELECT throws_ok(
  format($$ SELECT app.rpc_finish_model_call(%L::bigint, 'great', 12, %L::uuid) $$,
    (SELECT id FROM t47_great_call), (SELECT finish_token FROM t47_great_call)),
  '22023',
  NULL,
  'app.rpc_finish_model_call: ein unbekannter result_class (''great'') liefert weiterhin 22023'
);

-- -----------------------------------------------------------------------------
-- 6. T2-artig: _mg_open/_mg_throttle schreiben nicht in medizinische Tabellen.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.readiness_scores WHERE team_id = 'c4700000-0000-0000-0000-000000000001'),
  1,
  'app._mg_throttle/_mg_open: readiness_scores unveraendert (weiterhin genau die eine Testzeile)'
);
SELECT is(
  (SELECT count(*)::int FROM app.medical_clearances WHERE team_id = 'c4700000-0000-0000-0000-000000000001'),
  0,
  'app._mg_throttle/_mg_open: medical_clearances weiterhin leer, kein Schreibzugriff'
);
SELECT is(
  (SELECT count(*)::int FROM app.daily_checkins WHERE team_id = 'c4700000-0000-0000-0000-000000000001'),
  1,
  'app._mg_throttle/_mg_open: daily_checkins unveraendert (weiterhin genau die eine Testzeile)'
);

-- -----------------------------------------------------------------------------
-- 7. app._mg_open: fremde Rolle und fremdes Team werden abgelehnt, BEVOR eine
--    Zeile entsteht.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log),
  7,
  'Zwischenstand: sieben Zeilen aus den Abschnitten oben (Kontrollsumme vor den Ablehnungstests)'
);

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-forbidden-team', ARRAY['c4700000-0000-0000-0000-00000000ff11']::uuid[], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open: eine subject_id aus einem FREMDEN Team wird abgelehnt'
);

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000011', 'player');

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-forbidden-role', ARRAY['c4700000-0000-0000-0000-000000000011']::uuid[], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open: eine Rolle ausserhalb allowed_roles (player) wird abgelehnt'
);

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

-- F4 (Security-Review, Fixrunde): _mg_open prueft Secret UND Modul-Schalter
-- selbst, redundant zur jeweiligen Tuer.
SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-wrong-secret', ARRAY['c4700000-0000-0000-0000-000000000011']::uuid[], 'falsches-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F4): falsches p_context_secret wird abgelehnt, unabhaengig von der Tuer'
);

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-no-secret', ARRAY['c4700000-0000-0000-0000-000000000011']::uuid[], NULL) $$,
  '42501',
  NULL,
  'app._mg_open (F4): NULL p_context_secret wird abgelehnt'
);

-- jev_squad_check_enabled darf nur admin setzen (app._module_flag_setters, 41).
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', false);
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-flag-off', ARRAY['c4700000-0000-0000-0000-000000000011']::uuid[], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F4): abgeschalteter Modul-Schalter wird abgelehnt, unabhaengig von der Tuer'
);

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', true);
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

-- F3 (Security-Review, Fixrunde): mehrdimensionale Arrays, NULL-Elemente,
-- Doppel-Eintraege (count DISTINCT) und inaktive Personen werden abgelehnt.
SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-multi-dim', ARRAY[ARRAY['c4700000-0000-0000-0000-000000000011'::uuid]], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F3): ein mehrdimensionales subject_ids-Array wird abgelehnt'
);

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-null-elem', ARRAY['c4700000-0000-0000-0000-000000000011'::uuid, NULL], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F3): ein NULL-Element im subject_ids-Array wird abgelehnt'
);

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-dup-elem', ARRAY['c4700000-0000-0000-0000-000000000011'::uuid, 'c4700000-0000-0000-0000-000000000011'::uuid], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F3): ein doppelt uebergebenes subject_id (cardinality > count DISTINCT) wird abgelehnt'
);

UPDATE app.persons SET is_active = false WHERE id = 'c4700000-0000-0000-0000-000000000011';

SELECT throws_ok(
  $$ SELECT app._mg_open('ap69_squad_check', NULL, 'h-inactive', ARRAY['c4700000-0000-0000-0000-000000000011'::uuid], 't47-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'app._mg_open (F3): eine inaktive (geschredderte) Person als subject_id wird abgelehnt'
);

UPDATE app.persons SET is_active = true WHERE id = 'c4700000-0000-0000-0000-000000000011';

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log),
  7,
  'app._mg_open: die abgelehnten Aufrufe oben haben KEINE Zeile angelegt'
);

-- -----------------------------------------------------------------------------
-- 8. Ende-zu-Ende: app.rpc_squad_check_jev_context liefert weiterhin
--    candidates/refs, provider/model/rule_version kommen aus der Konfiguration.
--    Coach hat den Zaehler fuer ap69_squad_check in Abschnitt 4 bereits
--    ausgeschoepft -- ausserhalb des 5-Minuten-Fensters zurueckdatieren, wie
--    in 44_jev_rate_limit_and_finish_token.pgtap.sql (Punkt 86 Ablauftest).
-- -----------------------------------------------------------------------------

UPDATE app.model_call_log SET occurred_at = now() - interval '6 minutes'
 WHERE team_id = 'c4700000-0000-0000-0000-000000000001';

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

CREATE TEMP TABLE t47_e2e_result AS
SELECT app.rpc_squad_check_jev_context(
  'c4700000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
  't47-test-secret-mindestens-20-zeichen'
) AS result;

SELECT ok(
  (SELECT result -> 'candidates' FROM t47_e2e_result) @> jsonb_build_array(jsonb_build_object('ref', 'A01')),
  'app.rpc_squad_check_jev_context: liefert weiterhin einen Kandidaten mit Regel-Vorschlag full'
);

-- F1 (Security-Review, Fixrunde): call_id MUSS eine JSON-Zahl sein, kein
-- String -- lib/ai/gateway/run.ts prueft typeof openPayload.call_id ===
-- "number" und JEV liefe sonst in Produktion nie (->> statt -> war der Bug).
SELECT is(
  (SELECT jsonb_typeof(result -> 'call_id') FROM t47_e2e_result),
  'number',
  'app.rpc_squad_check_jev_context (F1): call_id ist eine JSON-Zahl, keine JSON-Zeichenkette'
);

SELECT is(
  (SELECT provider FROM app.model_call_log WHERE team_id = 'c4700000-0000-0000-0000-000000000001' ORDER BY occurred_at DESC LIMIT 1),
  'openrouter',
  'app.rpc_squad_check_jev_context: provider aus app._mg_purpose_config, identisch zu vorher'
);
SELECT is(
  (SELECT model FROM app.model_call_log WHERE team_id = 'c4700000-0000-0000-0000-000000000001' ORDER BY occurred_at DESC LIMIT 1),
  'typesafe/jev-1.13',
  'app.rpc_squad_check_jev_context: model aus app._mg_purpose_config, identisch zu vorher'
);
SELECT is(
  (SELECT rule_version FROM app.model_call_log WHERE team_id = 'c4700000-0000-0000-0000-000000000001' ORDER BY occurred_at DESC LIMIT 1),
  'v1',
  'app.rpc_squad_check_jev_context: rule_version aus app._mg_purpose_config, identisch zu vorher'
);
SELECT is(
  (SELECT p.id FROM app.model_call_subjects s JOIN app.persons p ON p.id = s.person_id
    WHERE s.call_id = (SELECT id FROM app.model_call_log WHERE team_id = 'c4700000-0000-0000-0000-000000000001' ORDER BY occurred_at DESC LIMIT 1)),
  'c4700000-0000-0000-0000-000000000011'::uuid,
  'app.rpc_squad_check_jev_context: model_call_subjects verweist auf die richtige Person (aus _mg_open)'
);

-- -----------------------------------------------------------------------------
-- 9. L4 (Fixrunde): Rechte-Tests, Rollenablehnung, Reihenfolge, Modul-Schalter.
-- -----------------------------------------------------------------------------

-- L4.1: Rechte fuer app.rpc_set_model_gateway_secret.
SELECT ok(
  NOT has_function_privilege('authenticated', 'app.rpc_set_model_gateway_secret(text)', 'EXECUTE'),
  'app.rpc_set_model_gateway_secret: kein EXECUTE fuer authenticated'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app.rpc_set_model_gateway_secret(text)', 'EXECUTE'),
  'app.rpc_set_model_gateway_secret: kein EXECUTE fuer anon'
);
SELECT ok(
  has_function_privilege('service_role', 'app.rpc_set_model_gateway_secret(text)', 'EXECUTE'),
  'app.rpc_set_model_gateway_secret: EXECUTE fuer service_role'
);

-- L4.2: anon kann keinen der internen Gateway-Helfer aufrufen.
SELECT ok(
  NOT has_function_privilege('anon', 'app._mg_secret_ok(text)', 'EXECUTE'),
  'app._mg_secret_ok: kein EXECUTE fuer anon'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app._mg_throttle(text, text)', 'EXECUTE'),
  'app._mg_throttle: kein EXECUTE fuer anon'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app._mg_open(text, uuid, text, uuid[], text)', 'EXECUTE'),
  'app._mg_open: kein EXECUTE fuer anon'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app._jev_context_secret_ok(text)', 'EXECUTE'),
  'app._jev_context_secret_ok: kein EXECUTE fuer anon'
);

-- L4.3: physio/doctor/admin werden an der Tuer abgelehnt (nur coach/
-- athletic_coach sind Staff, app.auth_is_staff()).
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000006', 'physio');
SELECT ok(
  app.is_denial(app.rpc_squad_check_jev_context(
    'c4700000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
    't47-test-secret-mindestens-20-zeichen'
  )),
  'app.rpc_squad_check_jev_context: physio wird abgelehnt (kein Staff)'
);

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000007', 'doctor');
SELECT ok(
  app.is_denial(app.rpc_squad_check_jev_context(
    'c4700000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
    't47-test-secret-mindestens-20-zeichen'
  )),
  'app.rpc_squad_check_jev_context: doctor wird abgelehnt (kein Staff)'
);

SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT ok(
  app.is_denial(app.rpc_squad_check_jev_context(
    'c4700000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
    't47-test-secret-mindestens-20-zeichen'
  )),
  'app.rpc_squad_check_jev_context: admin wird abgelehnt (kein Staff)'
);

-- L4.4: falsches Secret wird VOR NOT_FOUND abgelehnt (Reihenfolge-Test) --
-- eine nicht existierende session_id wuerde sonst zuerst P0002 werfen.
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');
SELECT lives_ok(
  $$ SELECT app.rpc_squad_check_jev_context(
       'c4700000-0000-0000-0000-00000000dead'::uuid, 60::smallint, 6::smallint,
       'falsches-secret-mindestens-20-zeichen'
     ) $$,
  'app.rpc_squad_check_jev_context: falsches Secret + nicht existierende session_id wirft NICHT P0002 (keine Exception)'
);
SELECT ok(
  app.is_denial(app.rpc_squad_check_jev_context(
    'c4700000-0000-0000-0000-00000000dead'::uuid, 60::smallint, 6::smallint,
    'falsches-secret-mindestens-20-zeichen'
  )),
  'app.rpc_squad_check_jev_context: falsches Secret liefert FORBIDDEN, VOR der Session-Suche (NOT_FOUND)'
);

-- L4.5: bei abgeschaltetem Modul-Flag entsteht keine Log-Zeile.
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', false);
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');
SELECT is(
  (SELECT count(*)::int FROM app.model_call_log),
  8,
  'Zwischenstand vor dem Modul-Flag-Test'
);
SELECT throws_ok(
  $$ SELECT app.rpc_squad_check_jev_context(
       'c4700000-0000-0000-0000-0000000000a1'::uuid, 60::smallint, 6::smallint,
       't47-test-secret-mindestens-20-zeichen'
     ) $$,
  '55000',
  NULL,
  'app.rpc_squad_check_jev_context: abgeschalteter Modul-Schalter liefert MODULE_DISABLED'
);
SELECT is(
  (SELECT count(*)::int FROM app.model_call_log),
  8,
  'app.rpc_squad_check_jev_context (L4.5): bei abgeschaltetem Modul-Flag entsteht KEINE Log-Zeile'
);
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('jev_squad_check_enabled', true);
SELECT app._t47_jwt('c4700000-0000-0000-0000-000000000002', 'coach');

SELECT * FROM finish();
ROLLBACK;
