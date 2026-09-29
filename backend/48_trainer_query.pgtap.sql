-- =============================================================================
-- 48_trainer_query.pgtap.sql — Gegenprobe zur Trainer-Query-Tuer (AP-70b)
--
-- Deckt ab:
--   - app._mg_daily_cap/rpc_trainer_query_open sind fuer authenticated/anon
--     nicht (bzw. nur ueber die public-Tuer) ausfuehrbar.
--   - Rollenmatrix: jede Rolle ausser coach/athletic_coach -> FORBIDDEN.
--   - Schalter trainer_query_enabled aus -> Absage.
--   - Secret fehlt/falsch -> Absage.
--   - Subject aus fremdem Team -> Absage.
--   - Rueckgabe hat EXAKT die 5 Schluessel, KEINE Kaderdaten.
--   - Snapshot-Test: die exakte Schluesselmenge von public.rpc_trainer_morning_ops
--     (muss absichtlich ROT werden, wenn die Tuer-Payload waechst).
--   - Tagesdeckel (200/Tag/Team) und die 10/5min-Drosselung je Person.
--   - trainer_query_enabled darf nur admin setzen.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(36);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4800000-0000-0000-0000-000000000001','Team C48','Europe/Berlin'),
  ('c4800000-0000-0000-0000-00000000ffff','Team C48-Fremd','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, person_position, shirt_number, auth_user_id, is_active) VALUES
  ('c4800000-0000-0000-0000-000000000002','c4800000-0000-0000-0000-000000000001','Coach C48',NULL,NULL,'c4800000-0000-0000-0000-000000000002',true),
  ('c4800000-0000-0000-0000-000000000005','c4800000-0000-0000-0000-000000000001','Admin C48',NULL,NULL,'c4800000-0000-0000-0000-000000000005',true),
  ('c4800000-0000-0000-0000-000000000006','c4800000-0000-0000-0000-000000000001','Physio C48',NULL,NULL,'c4800000-0000-0000-0000-000000000006',true),
  ('c4800000-0000-0000-0000-000000000007','c4800000-0000-0000-0000-000000000001','Doctor C48',NULL,NULL,'c4800000-0000-0000-0000-000000000007',true),
  ('c4800000-0000-0000-0000-000000000011','c4800000-0000-0000-0000-000000000001','P1 Markantname','sturm',11,NULL,true),
  ('c4800000-0000-0000-0000-00000000ff11','c4800000-0000-0000-0000-00000000ffff','P-Fremd Markantname','sturm',12,NULL,true);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from, valid_to)
SELECT p.team_id, p.id,
       CASE p.id WHEN 'c4800000-0000-0000-0000-000000000002' THEN 'coach'
                 WHEN 'c4800000-0000-0000-0000-000000000005' THEN 'admin'
                 WHEN 'c4800000-0000-0000-0000-000000000006' THEN 'physio'
                 WHEN 'c4800000-0000-0000-0000-000000000007' THEN 'doctor'
                 ELSE 'player' END::app.app_role,
       now() - interval '90 days', NULL
  FROM app.persons p WHERE p.id::text LIKE 'c4800000-0000-0000-0000-0000000000%';

CREATE OR REPLACE FUNCTION app._t48_jwt(p_sub text, p_role text, p_team text DEFAULT 'c4800000-0000-0000-0000-000000000001')
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', p_team)::text, true);
$$;

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('trainer_query_enabled', true);
SELECT app.rpc_set_jev_context_secret('t48-test-secret-mindestens-20-zeichen');

-- -----------------------------------------------------------------------------
-- 1. Rechte.
-- -----------------------------------------------------------------------------

SELECT ok(
  NOT has_function_privilege('authenticated', 'app._mg_daily_cap(text, text, integer)', 'EXECUTE'),
  'app._mg_daily_cap: kein EXECUTE fuer authenticated'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app._mg_daily_cap(text, text, integer)', 'EXECUTE'),
  'app._mg_daily_cap: kein EXECUTE fuer anon'
);
SELECT ok(
  NOT has_function_privilege('anon', 'app.rpc_trainer_query_open(text, uuid[], text)', 'EXECUTE'),
  'app.rpc_trainer_query_open: kein EXECUTE fuer anon'
);
SELECT ok(
  has_function_privilege('authenticated', 'app.rpc_trainer_query_open(text, uuid[], text)', 'EXECUTE'),
  'app.rpc_trainer_query_open: EXECUTE fuer authenticated (Rollenpruefung im Rumpf)'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.rpc_trainer_query_open(text, uuid[], text)', 'EXECUTE'),
  'public.rpc_trainer_query_open: kein EXECUTE fuer anon'
);

-- -----------------------------------------------------------------------------
-- 2. Konfiguration.
-- -----------------------------------------------------------------------------

SELECT is(
  app._mg_purpose_config('ap70_trainer_query'),
  jsonb_build_object(
    'provider', 'openrouter', 'model', 'typesafe/jev-1.13', 'rule_version', 'v1',
    'flag', 'trainer_query_enabled', 'rate_max', 10, 'rate_window', '5 minutes',
    'allowed_roles', jsonb_build_array('coach', 'athletic_coach'),
    'allow_empty_subjects', true
  ),
  'app._mg_purpose_config(''ap70_trainer_query''): feste Konfiguration'
);

-- -----------------------------------------------------------------------------
-- 3. Rollenmatrix: jede Rolle ausser coach/athletic_coach -> FORBIDDEN.
-- -----------------------------------------------------------------------------

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000005', 'admin');
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-admin', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: admin wird abgelehnt (kein Staff)'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000006', 'physio');
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-physio', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: physio wird abgelehnt (kein Staff)'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000007', 'doctor');
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-doctor', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: doctor wird abgelehnt (kein Staff)'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000011', 'player');
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-player', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: player wird abgelehnt (kein Staff)'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  NOT app.is_denial(app.rpc_trainer_query_open('h-coach-ok', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: coach wird akzeptiert'
);

-- -----------------------------------------------------------------------------
-- 4. Schalter aus -> Absage, keine neue Zeile.
-- -----------------------------------------------------------------------------

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('trainer_query_enabled', false);
SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000002', 'coach');

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE purpose = 'ap70_trainer_query'),
  1,
  'Zwischenstand vor dem Schalter-Test (genau der eine erfolgreiche Aufruf oben)'
);
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-flag-off', ARRAY[]::uuid[], 't48-test-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: abgeschalteter Schalter liefert Absage'
);
SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE purpose = 'ap70_trainer_query'),
  1,
  'rpc_trainer_query_open: bei abgeschaltetem Schalter entsteht KEINE neue Zeile'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000005', 'admin');
SELECT app.rpc_set_module_flag('trainer_query_enabled', true);
SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000002', 'coach');

-- -----------------------------------------------------------------------------
-- 5. Secret fehlt/falsch -> Absage.
-- -----------------------------------------------------------------------------

SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-no-secret', ARRAY[]::uuid[], NULL)),
  'rpc_trainer_query_open: fehlendes Secret liefert Absage'
);
SELECT ok(
  app.is_denial(app.rpc_trainer_query_open('h-wrong-secret', ARRAY[]::uuid[], 'falsches-secret-mindestens-20-zeichen')),
  'rpc_trainer_query_open: falsches Secret liefert Absage'
);

-- -----------------------------------------------------------------------------
-- 6. Subject aus fremdem Team -> Absage, keine Zeile.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE purpose = 'ap70_trainer_query'),
  1,
  'Zwischenstand vor dem Fremdteam-Test'
);
SELECT throws_ok(
  $$ SELECT app.rpc_trainer_query_open('h-foreign-subject', ARRAY['c4800000-0000-0000-0000-00000000ff11']::uuid[], 't48-test-secret-mindestens-20-zeichen') $$,
  '42501',
  NULL,
  'rpc_trainer_query_open: eine subject_id aus einem FREMDEN Team wird abgelehnt'
);
SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE purpose = 'ap70_trainer_query'),
  1,
  'rpc_trainer_query_open: der Fremdteam-Versuch hat KEINE Zeile angelegt'
);

-- -----------------------------------------------------------------------------
-- 7. Rueckgabe hat EXAKT die 5 Schluessel, keine Kaderdaten.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE t48_open_result AS
SELECT app.rpc_trainer_query_open('h-shape', ARRAY['c4800000-0000-0000-0000-000000000011']::uuid[], 't48-test-secret-mindestens-20-zeichen') AS result;

SELECT is(
  (SELECT array(SELECT jsonb_object_keys(result) ORDER BY 1) FROM t48_open_result),
  ARRAY['call_id', 'finish_token', 'model', 'provider', 'rule_version'],
  'rpc_trainer_query_open: Rueckgabe hat EXAKT die 5 erlaubten Schluessel, keine Kaderdaten'
);
SELECT is(
  (SELECT jsonb_typeof(result -> 'call_id') FROM t48_open_result),
  'number',
  'rpc_trainer_query_open: call_id ist eine JSON-Zahl (nicht ->> verwechselt)'
);
SELECT is(
  (SELECT result ->> 'model' FROM t48_open_result),
  'typesafe/jev-1.13',
  'rpc_trainer_query_open: model kommt aus app._mg_purpose_config'
);

-- -----------------------------------------------------------------------------
-- 8. Snapshot-Test: exakte Schluesselmenge von public.rpc_trainer_morning_ops.
--    Wird die Tuer-Payload erweitert, muss dieser Test ROT werden -- das
--    erzwingt ein manuelles Allowlist-Review (lib/trainerQuery/schema.ts)
--    bei jeder kuenftigen Erweiterung, kein automatisches Mitwachsen.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE t48_door_payload AS
SELECT public.rpc_trainer_morning_ops() AS payload;

SELECT is(
  (SELECT array(SELECT jsonb_object_keys(payload) ORDER BY 1) FROM t48_door_payload),
  ARRAY['asOf', 'kaderName', 'members', 'syncState'],
  'SNAPSHOT: Top-Level-Schluessel von rpc_trainer_morning_ops unveraendert'
);
SELECT is(
  (SELECT array(SELECT jsonb_object_keys(payload -> 'members' -> 0) ORDER BY 1) FROM t48_door_payload),
  ARRAY['attendance', 'baseline', 'hasCheckIn', 'medicalClearance', 'medicalStatus', 'player', 'readiness', 'todayEvent'],
  'SNAPSHOT: Mitglieds-Schluessel von rpc_trainer_morning_ops unveraendert -- waechst dieser Test rot, MUSS lib/trainerQuery/schema.ts (Allowlist) manuell geprueft werden'
);
SELECT is(
  (SELECT array(SELECT jsonb_object_keys(payload -> 'members' -> 0 -> 'player') ORDER BY 1) FROM t48_door_payload),
  ARRAY['id', 'jersey', 'name', 'position'],
  'SNAPSHOT: player-Unterschluessel unveraendert'
);
SELECT is(
  (SELECT array(SELECT jsonb_object_keys(payload -> 'members' -> 0 -> 'readiness') ORDER BY 1) FROM t48_door_payload),
  ARRAY['band'],
  'SNAPSHOT: readiness-Unterschluessel unveraendert (nur band)'
);
SELECT is(
  (SELECT array(SELECT jsonb_object_keys(payload -> 'members' -> 0 -> 'baseline') ORDER BY 1) FROM t48_door_payload),
  ARRAY['rollingAvg', 'series'],
  'SNAPSHOT: baseline-Unterschluessel unveraendert (ausserhalb der Allowlist, darf nie an das Modell)'
);

-- -----------------------------------------------------------------------------
-- 9. Drosselung: 10/5min je Person.
-- -----------------------------------------------------------------------------

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000002', 'coach');

DO $$
DECLARE i integer;
BEGIN
  FOR i IN 1..8 LOOP
    PERFORM app._mg_throttle('ap70_trainer_query', 'c48.throttle');
    INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count)
    VALUES ('c4800000-0000-0000-0000-000000000001', 'ap70_trainer_query', 'person', 'c4800000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h-fill-' || i, 0);
  END LOOP;
END $$;

SELECT throws_ok(
  $$ SELECT app._mg_throttle('ap70_trainer_query', 'c48.throttle') $$,
  '55000',
  NULL,
  'app._mg_throttle: der elfte Aufruf fuer ap70_trainer_query (10/5min) wird RATE_LIMITED'
);

-- -----------------------------------------------------------------------------
-- 10. Tagesdeckel: 200/Tag je Team.
-- -----------------------------------------------------------------------------

-- Aktuelle Zeilen (aus den Abschnitten oben) auf gestern zuruecksetzen, damit
-- der 5-Minuten-Zaehler nicht mehr greift, aber innerhalb des Tagesdeckels
-- weiter mitzaehlt -- date_trunc('day', now()) filtert nur den Kalendertag,
-- nicht die 5 Minuten.
INSERT INTO app.model_call_log (team_id, purpose, actor_kind, actor_id, actor_role, provider, model, rule_version, input_hash, subject_count, occurred_at)
SELECT 'c4800000-0000-0000-0000-000000000001', 'ap70_trainer_query', 'person', 'c4800000-0000-0000-0000-000000000002', 'coach', 'openrouter', 'typesafe/jev-1.13', 'v1', 'h-daily-' || gs, 0, now()
  FROM generate_series(1, 190) gs;

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE team_id = 'c4800000-0000-0000-0000-000000000001' AND purpose = 'ap70_trainer_query' AND occurred_at >= date_trunc('day', now())),
  200,
  'Zwischenstand: 200 Zeilen fuer heute vor dem Tagesdeckel-Test'
);
SELECT throws_ok(
  $$ SELECT app._mg_daily_cap('ap70_trainer_query', 'c48.daily', 200) $$,
  '55000',
  NULL,
  'app._mg_daily_cap: der 201. Aufruf heute (200/Tag/Team) wird RATE_LIMITED'
);
SELECT lives_ok(
  $$ SELECT app._mg_daily_cap('ap69_squad_check', 'c48.daily.other', 200) $$,
  'app._mg_daily_cap: ein ANDERER Zweck ist vom Tagesdeckel von ap70_trainer_query unberuehrt'
);

-- -----------------------------------------------------------------------------
-- 11. trainer_query_enabled darf nur admin setzen.
-- -----------------------------------------------------------------------------

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000002', 'coach');
SELECT ok(
  app.is_denial(app.rpc_set_module_flag('trainer_query_enabled', false)),
  'rpc_set_module_flag: coach darf trainer_query_enabled NICHT setzen'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000006', 'physio');
SELECT ok(
  app.is_denial(app.rpc_set_module_flag('trainer_query_enabled', false)),
  'rpc_set_module_flag: physio darf trainer_query_enabled NICHT setzen'
);

SELECT app._t48_jwt('c4800000-0000-0000-0000-000000000005', 'admin');
SELECT ok(
  NOT app.is_denial(app.rpc_set_module_flag('trainer_query_enabled', false)),
  'rpc_set_module_flag: admin darf trainer_query_enabled setzen'
);

-- -----------------------------------------------------------------------------
-- 12. app._mg_open/_mg_daily_cap schreiben nicht in medizinische Tabellen.
-- -----------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int FROM app.medical_clearances WHERE team_id = 'c4800000-0000-0000-0000-000000000001'),
  0,
  'rpc_trainer_query_open/_mg_daily_cap: medical_clearances bleibt leer, kein Schreibzugriff'
);
SELECT is(
  (SELECT count(*)::int FROM app.readiness_scores WHERE team_id = 'c4800000-0000-0000-0000-000000000001'),
  0,
  'rpc_trainer_query_open/_mg_daily_cap: readiness_scores bleibt leer, kein Schreibzugriff'
);

SELECT * FROM finish();
ROLLBACK;
