-- =============================================================================
-- 45_model_call_log_purge_cron.pgtap.sql — Gegenprobe zu Punkt 88
--
-- pg_cron selbst ist lokal nicht installiert (siehe Kopfkommentar der
-- Migration) -- geprueft wird die Wrapper-Funktion app.cron_purge_model_call_log
-- direkt: eine Zeile aelter als 1 Jahr wird geloescht, eine juengere bleibt
-- stehen. Zusaetzlich: app.model_call_subjects raeumt per ON DELETE CASCADE
-- automatisch mit auf.
--
-- Laeuft in einer Transaktion und rollt zurueck.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(4);

INSERT INTO app.teams (id, name, timezone) VALUES
  ('c4500000-0000-0000-0000-000000000001','Team C45','Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, is_active) VALUES
  ('c4500000-0000-0000-0000-000000000002','c4500000-0000-0000-0000-000000000001','Coach C45','c4500000-0000-0000-0000-000000000002',true),
  ('c4500000-0000-0000-0000-000000000011','c4500000-0000-0000-0000-000000000001','P1 Markantname',NULL,true);

-- Alte Zeile (aelter als 1 Jahr) mit einem Subject -- prueft das CASCADE mit.
WITH ins AS (
  INSERT INTO app.model_call_log (
    team_id, occurred_at, purpose, actor_kind, actor_id, actor_role,
    provider, model, rule_version, input_hash, subject_count, result_class
  ) VALUES (
    'c4500000-0000-0000-0000-000000000001', now() - interval '370 days', 'ap69_squad_check',
    'person', 'c4500000-0000-0000-0000-000000000002', 'coach',
    'openrouter', 'typesafe/jev-1.13', 'v1', 'old-hash', 1, 'ok'
  ) RETURNING id
)
SELECT id INTO TEMP TABLE t45_old_id FROM ins;

INSERT INTO app.model_call_subjects (call_id, team_id, person_id)
SELECT id, 'c4500000-0000-0000-0000-000000000001', 'c4500000-0000-0000-0000-000000000011'
  FROM t45_old_id;

-- Junge Zeile (innerhalb 1 Jahr) -- muss stehen bleiben.
WITH ins AS (
  INSERT INTO app.model_call_log (
    team_id, occurred_at, purpose, actor_kind, actor_id, actor_role,
    provider, model, rule_version, input_hash, subject_count, result_class
  ) VALUES (
    'c4500000-0000-0000-0000-000000000001', now() - interval '10 days', 'ap69_squad_check',
    'person', 'c4500000-0000-0000-0000-000000000002', 'coach',
    'openrouter', 'typesafe/jev-1.13', 'v1', 'young-hash', 1, 'ok'
  ) RETURNING id
)
SELECT id INTO TEMP TABLE t45_young_id FROM ins;

SELECT app.cron_purge_model_call_log();

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE id = (SELECT id FROM t45_old_id)),
  0,
  'Punkt 88: eine model_call_log-Zeile aelter als 1 Jahr wird vom Nachtlauf geloescht'
);

SELECT is(
  (SELECT count(*)::int FROM app.model_call_subjects WHERE call_id = (SELECT id FROM t45_old_id)),
  0,
  'Punkt 88: model_call_subjects der geloeschten Zeile geht per ON DELETE CASCADE mit'
);

SELECT is(
  (SELECT count(*)::int FROM app.model_call_log WHERE id = (SELECT id FROM t45_young_id)),
  1,
  'Punkt 88: eine juengere Zeile (10 Tage) bleibt stehen'
);

SELECT is(
  has_function_privilege('authenticated', 'app.cron_purge_model_call_log()', 'EXECUTE'),
  false,
  'Punkt 88: authenticated darf den Nachtlauf NICHT ausfuehren'
);

SELECT * FROM finish();
ROLLBACK;
