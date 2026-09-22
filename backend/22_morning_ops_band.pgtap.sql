-- =============================================================================
-- 22_morning_ops_band.pgtap.sql — Medizin-Gate im Trainer-Payload (Befund N7)
--
-- Was diese Suite festhaelt: app.rpc_morning_ops() und die Tuer
-- public.rpc_trainer_morning_ops() geben dem Trainerteam NUR readiness.band.
-- score_total und factors sind fuer coach und athletic_coach in der
-- kanonischen Matrix fett mit "-" markiert (Module/Modul-Rollen-Medizin-Gate
-- Abschnitt 5). Bis zum 2026-09-22 standen beide im Payload, live erreichbar
-- ueber den einzigen RPC, den der Web Client ruft.
--
-- Die Suite prueft drei Dinge, nicht nur eines:
--   1. Trainer bekommt band, und weder value noch factors (auch nicht als
--      null-Schluessel, und auch nicht bei fehlender Readiness-Zeile).
--   2. Medizin und self sind unveraendert: app.rpc_readiness_full liefert
--      physio, doctor und der eigenen Person weiter score_total UND factors.
--   3. Der Waechter und die Spaltenrechte sind unveraendert: die zweite
--      Schutzschicht auf app.readiness_scores haelt weiter dagegen.
--
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 08_dashboard_migration.sql,
-- 10_auth_hook.sql, 12_trainer_api.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(36);


-- ---------------------------------------------------------------------------
-- Punkt 55 (2026-09-22): app.rpc_readiness_full(uuid, date, date) hat seit backend/26_app_execute_revoke.sql
-- kein EXECUTE mehr fuer authenticated (Befund N5). Diese Suite prueft ihren Rumpf,
-- nicht ihr Recht, und ruft sie unter SET ROLE authenticated auf. Sie leiht sich das
-- Recht deshalb fuer die Dauer dieser Transaktion zurueck, der ROLLBACK am Ende nimmt
-- es wieder. Dass das Recht im Normalbetrieb fehlt, prueft Suite 26.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION app.rpc_readiness_full(uuid, date, date) TO authenticated;

INSERT INTO app.teams (id, name, timezone) VALUES
  ('22222222-2222-2222-2222-222222222222', 'Band Team', 'Europe/Berlin');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number, person_position) VALUES
  ('d1000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Trainerin',  'd2000000-0000-0000-0000-000000000001', NULL, 'Cheftrainerin'),
  ('d1000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Athletik',   'd2000000-0000-0000-0000-000000000002', NULL, 'Athletik'),
  ('d1000000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'Physio',     'd2000000-0000-0000-0000-000000000003', NULL, 'Physio'),
  ('d1000000-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 'Spielerin',  'd2000000-0000-0000-0000-000000000004', 7,    'Rueckraum'),
  ('d1000000-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222', 'Ohne Score', 'd2000000-0000-0000-0000-000000000005', 9,    'Kreis');

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000001', 'coach',           now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000002', 'athletic_coach',  now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000003', 'physio',          now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000004', 'player',          now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000005', 'player',          now() - interval '1 day');

-- Nummer 7 hat einen Score von heute, Nummer 9 hat keinen.
INSERT INTO app.readiness_scores (team_id, person_id, date, score_total, band, factors) VALUES
  ('22222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000004', current_date,
   83.0, 'high', '{"sleep": 0.9, "mental": 0.7, "soreness": 0.4}'::jsonb);

CREATE FUNCTION app._t22_jwt(p_sub text, p_role text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', '22222222-2222-2222-2222-222222222222')::text,
    true);
$$;

-- Ein Mitglied des Payloads ueber seine Rueckennummer.
CREATE FUNCTION app._t22_member(p_jersey int)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT m FROM jsonb_array_elements(app.rpc_morning_ops() -> 'members') m
  WHERE (m -> 'player' ->> 'jersey')::int = p_jersey;
$$;

SELECT has_function('app', 'rpc_morning_ops', ARRAY[]::text[], 'app.rpc_morning_ops existiert');

-- ---------------------------------------------------------------------------
-- 1. Trainer (coach): band ja, value und factors nein
-- ---------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000001', 'coach');

SELECT ok(app._t22_member(7) -> 'readiness' ? 'band',
  'Trainer: readiness traegt den Schluessel band');
SELECT is(app._t22_member(7) -> 'readiness' ->> 'band', 'high',
  'Trainer: band ist der Wert aus app.readiness_scores');
SELECT ok(NOT (app._t22_member(7) -> 'readiness' ? 'value'),
  'Trainer: readiness traegt KEINEN Schluessel value');
SELECT ok(NOT (app._t22_member(7) -> 'readiness' ? 'factors'),
  'Trainer: readiness traegt KEINEN Schluessel factors');
SELECT is((SELECT count(*)::int FROM jsonb_object_keys(app._t22_member(7) -> 'readiness')), 1,
  'Trainer: readiness hat genau einen Schluessel');

-- Der ganze Payload als Text: kein Zahlwert, kein Faktorname.
SELECT ok(app.rpc_morning_ops()::text NOT LIKE '%factors%',
  'Trainer: der ganze Payload nennt factors nirgends');
SELECT ok(app.rpc_morning_ops()::text NOT LIKE '%soreness%',
  'Trainer: der ganze Payload nennt soreness nirgends');
SELECT ok(app.rpc_morning_ops()::text NOT LIKE '%"value"%',
  'Trainer: der ganze Payload nennt "value" nirgends');
SELECT ok(app.rpc_morning_ops()::text NOT LIKE '%83%',
  'Trainer: der Zahlwert 83 steht nirgends im Payload');

-- ---------------------------------------------------------------------------
-- 2. Athletiktrainer: dieselbe Zeile der Matrix, dasselbe Ergebnis
-- ---------------------------------------------------------------------------
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000002', 'athletic_coach');
SELECT is(app._t22_member(7) -> 'readiness' ->> 'band', 'high',
  'Athletik: band kommt an');
SELECT ok(NOT (app._t22_member(7) -> 'readiness' ? 'value'),
  'Athletik: kein value');
SELECT ok(NOT (app._t22_member(7) -> 'readiness' ? 'factors'),
  'Athletik: kein factors');

-- ---------------------------------------------------------------------------
-- 3. Person ohne Readiness-Zeile: band ist null, sonst aendert sich nichts
-- ---------------------------------------------------------------------------
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000001', 'coach');
SELECT ok(app._t22_member(9) -> 'readiness' ? 'band',
  'Ohne Score: der Schluessel band ist trotzdem da');
SELECT is(app._t22_member(9) -> 'readiness' ->> 'band', NULL,
  'Ohne Score: band ist null');
SELECT is((SELECT count(*)::int FROM jsonb_object_keys(app._t22_member(9) -> 'readiness')), 1,
  'Ohne Score: readiness hat weiter genau einen Schluessel');

-- ---------------------------------------------------------------------------
-- 4. Alles uebrige am Payload ist unveraendert
-- ---------------------------------------------------------------------------
SELECT is(app.rpc_morning_ops() ->> 'kaderName', 'Band Team',
  'Unveraendert: kaderName');
SELECT is(jsonb_array_length(app.rpc_morning_ops() -> 'members'), 5,
  'Unveraendert: alle fuenf aktiven Personen');
SELECT is(app._t22_member(7) -> 'player' ->> 'name', 'Spielerin',
  'Unveraendert: player.name');
SELECT is(app._t22_member(7) ->> 'hasCheckIn', 'false',
  'Unveraendert: hasCheckIn (heute kein Check-In)');
SELECT is(app._t22_member(7) ->> 'medicalStatus', 'green',
  'Unveraendert: medicalStatus');
SELECT ok(app._t22_member(7) ? 'baseline',
  'Unveraendert: baseline');
SELECT is(public.rpc_trainer_morning_ops(), app.rpc_morning_ops(),
  'Die Tuer liefert dasselbe Payload wie app.rpc_morning_ops');

-- ---------------------------------------------------------------------------
-- 5. Die zweite Schutzschicht steht weiter: Spaltenrechte
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT ok(NOT has_column_privilege('authenticated', 'app.readiness_scores', 'score_total', 'SELECT'),
  'Spaltenrecht: authenticated darf score_total nicht lesen');
SELECT ok(NOT has_column_privilege('authenticated', 'app.readiness_scores', 'factors', 'SELECT'),
  'Spaltenrecht: authenticated darf factors nicht lesen');
SELECT ok(has_column_privilege('authenticated', 'app.readiness_scores', 'band', 'SELECT'),
  'Spaltenrecht: authenticated darf band lesen');

SET ROLE authenticated;
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000001', 'coach');
SELECT throws_ok($$SELECT score_total FROM app.readiness_scores$$, '42501', NULL,
  'Trainer direkt auf die Tabelle: permission denied');

-- ---------------------------------------------------------------------------
-- 6. Medizin und self sind unveraendert
-- ---------------------------------------------------------------------------
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000003', 'physio');
SELECT is((SELECT r.score_total FROM app.rpc_readiness_full('d1000000-0000-0000-0000-000000000004') r), 83.0,
  'Medizin unveraendert: physio bekommt score_total');
SELECT is((SELECT r.factors ->> 'soreness' FROM app.rpc_readiness_full('d1000000-0000-0000-0000-000000000004') r), '0.4',
  'Medizin unveraendert: physio bekommt factors');

SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000004', 'player');
SELECT is((SELECT r.score_total FROM app.rpc_readiness_full('d1000000-0000-0000-0000-000000000004') r), 83.0,
  'self unveraendert: die Spielerin bekommt ihren score_total');
SELECT is((SELECT r.factors ->> 'sleep' FROM app.rpc_readiness_full('d1000000-0000-0000-0000-000000000004') r), '0.9',
  'self unveraendert: die Spielerin bekommt ihre factors');

-- ---------------------------------------------------------------------------
-- 7. Der Waechter ist unveraendert: nur Staff kommt ueberhaupt herein
-- ---------------------------------------------------------------------------
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN',
  'Waechter unveraendert: Spielerin bekommt FORBIDDEN');
SELECT app._t22_jwt('d2000000-0000-0000-0000-000000000003', 'physio');
SELECT throws_ok($$SELECT app.rpc_morning_ops()$$, '42501', 'FORBIDDEN',
  'Waechter unveraendert: physio bekommt FORBIDDEN');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 8. Regressionsanker am Funktionsrumpf selbst
-- ---------------------------------------------------------------------------
-- Gegen rs.score_total, nicht gegen score_total: der Kommentar im Rumpf nennt
-- das Wort absichtlich, die Spalte wird nicht mehr gelesen.
SELECT ok(pg_get_functiondef('app.rpc_morning_ops()'::regprocedure) NOT LIKE '%rs.score_total%',
  'Regressionsanker: der Rumpf liest rs.score_total nicht mehr');
SELECT ok(pg_get_functiondef('app.rpc_morning_ops()'::regprocedure) NOT LIKE '%rs.factors%',
  'Regressionsanker: der Rumpf nennt rs.factors nicht mehr');
SELECT ok(pg_get_functiondef('app.rpc_morning_ops()'::regprocedure) LIKE '%rs.band%',
  'Regressionsanker: der Rumpf nennt rs.band weiter');

SELECT * FROM finish();
ROLLBACK;
