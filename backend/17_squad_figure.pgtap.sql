-- =============================================================================
-- 17_squad_figure.pgtap.sql — Kadervorgabe und Darstellungspraeferenz (AP-43)
-- Voraussetzung: 08_reconciling.sql, 09_rpcs.sql, 10_auth_hook.sql, 17_squad_figure.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Die Suite prueft zwei Dinge, die auseinanderfallen koennen: dass die Figur
-- richtig aufgeloest wird, und dass die Praeferenz niemandem ausser der Person
-- selbst sichtbar ist. Das zweite ist der Grund, warum es kein Geschlechtsfeld
-- gibt (Modul-Body-Map 3.2b).
-- =============================================================================

BEGIN;
SET search_path = public, pgtap;
SELECT plan(29);

INSERT INTO app.teams (id, name, timezone, squad_type) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Frauen Kader',   'Europe/Berlin', 'frauen'),
  ('22222222-2222-2222-2222-222222222222', 'Maenner Kader',  'Europe/Berlin', 'maenner'),
  ('33333333-3333-3333-3333-333333333333', 'Nachwuchs',      'Europe/Berlin', 'gemischt');

INSERT INTO app.persons (id, team_id, display_name, auth_user_id, shirt_number) VALUES
  ('c1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Spielerin', 'c2000000-0000-0000-0000-000000000001', 7),
  ('c1000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Spieler',   'c2000000-0000-0000-0000-000000000002', 9),
  ('c1000000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333', 'Talent',    'c2000000-0000-0000-0000-000000000003', 11),
  ('c1000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Trainerin', 'c2000000-0000-0000-0000-000000000004', NULL);

INSERT INTO app.role_assignments (team_id, person_id, role, valid_from) VALUES
  ('11111111-1111-1111-1111-111111111111', 'c1000000-0000-0000-0000-000000000001', 'player', now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222', 'c1000000-0000-0000-0000-000000000002', 'player', now() - interval '1 day'),
  ('33333333-3333-3333-3333-333333333333', 'c1000000-0000-0000-0000-000000000003', 'player', now() - interval '1 day'),
  ('11111111-1111-1111-1111-111111111111', 'c1000000-0000-0000-0000-000000000004', 'coach',  now() - interval '1 day');

CREATE FUNCTION app._t_jwt2(p_sub text, p_role text, p_team text)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'app_role', p_role,
                       'team_id', p_team)::text,
    true);
$$;

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------
SELECT has_column('app', 'teams', 'squad_type', 'app.teams.squad_type existiert');
SELECT has_column('app', 'persons', 'body_map_figure', 'app.persons.body_map_figure existiert');
SELECT col_not_null('app', 'teams', 'squad_type', 'squad_type ist gesetzt, nie NULL');
SELECT col_not_null('app', 'persons', 'body_map_figure', 'body_map_figure ist gesetzt, nie NULL');
SELECT col_default_is('app', 'persons', 'body_map_figure', 'aus_dem_team',
  'Vorgabe ist aus_dem_team: die Figur kommt ohne Zutun aus dem Kader');
SELECT col_default_is('app', 'teams', 'squad_type', 'unbestimmt',
  'Vorgabe ist unbestimmt, also die neutrale Figur');

-- Kein Geschlechtsfeld an der Person (Entscheidung 6, Modul-Body-Map 3.2b).
SELECT hasnt_column('app', 'persons', 'gender', 'Kein Feld gender an der Person');
SELECT hasnt_column('app', 'persons', 'geschlecht', 'Kein Feld geschlecht an der Person');
SELECT hasnt_column('app', 'persons', 'sex', 'Kein Feld sex an der Person');

SELECT set_eq(
  $$SELECT unnest(enum_range(NULL::app.app_squad_type))::text$$,
  $$VALUES ('frauen'), ('maenner'), ('gemischt'), ('unbestimmt')$$,
  'squad_type kennt genau vier Werte');
SELECT set_eq(
  $$SELECT unnest(enum_range(NULL::app.app_body_map_figure))::text$$,
  $$VALUES ('aus_dem_team'), ('weiblich'), ('maennlich'), ('neutral')$$,
  'body_map_figure kennt genau vier Werte');

-- ---------------------------------------------------------------------------
-- Aufloesung: Praeferenz schlaegt Kadervorgabe
-- ---------------------------------------------------------------------------
SELECT is(app.body_map_figure_for('aus_dem_team', 'frauen'),     'weiblich',  'Frauenkader ohne Praeferenz fuehrt auf weiblich');
SELECT is(app.body_map_figure_for('aus_dem_team', 'maenner'),    'maennlich', 'Maennerkader ohne Praeferenz fuehrt auf maennlich');
SELECT is(app.body_map_figure_for('aus_dem_team', 'gemischt'),   'neutral',   'Gemischter Kader fuehrt auf neutral');
SELECT is(app.body_map_figure_for('aus_dem_team', 'unbestimmt'), 'neutral',   'Unbestimmter Kader fuehrt auf neutral');
SELECT is(app.body_map_figure_for('neutral',      'frauen'),     'neutral',   'Die eigene Praeferenz schlaegt die Kadervorgabe');
SELECT is(app.body_map_figure_for('maennlich',    'frauen'),     'maennlich', 'Auch quer zur Kadervorgabe, ohne Begruendung');

-- ---------------------------------------------------------------------------
-- Der eigene Leseweg
-- ---------------------------------------------------------------------------
SET ROLE authenticated;
SELECT app._t_jwt2('c2000000-0000-0000-0000-000000000001', 'player', '11111111-1111-1111-1111-111111111111');
SELECT is((app.rpc_my_body_map_figure() ->> 'figure'), 'weiblich',
  'Spielerin im Frauenkader bekommt ohne Zutun die weibliche Figur');
SELECT is((app.rpc_my_body_map_figure() ->> 'preference'), 'aus_dem_team',
  'Die Praeferenz steht auf der Vorgabe, es gab keine Frage im Onboarding');

SELECT is((app.rpc_set_my_body_map_figure('neutral') ->> 'figure'), 'neutral',
  'Umstellen im eigenen Profil wirkt sofort');
SELECT is((app.rpc_my_body_map_figure() ->> 'figure'), 'neutral',
  'Und bleibt beim naechsten Lesen stehen');
SELECT throws_ok($$SELECT app.rpc_set_my_body_map_figure('divers')$$,
  '22023', 'INVALID: persons.body_map_figure',
  'Ein Wert ausserhalb der vier wird abgelehnt. Das Feld ist Darstellung, keine Angabe ueber einen Menschen');

SELECT app._t_jwt2('c2000000-0000-0000-0000-000000000003', 'player', '33333333-3333-3333-3333-333333333333');
SELECT is((app.rpc_my_body_map_figure() ->> 'figure'), 'neutral',
  'Im Nachwuchs mit gemischtem Kader steht die neutrale Figur, als gleichwertige Vorgabe');

-- ---------------------------------------------------------------------------
-- Sichtbarkeit: die Praeferenz gehoert der Person, nicht dem Kader
-- ---------------------------------------------------------------------------
SELECT app._t_jwt2('c2000000-0000-0000-0000-000000000004', 'coach', '11111111-1111-1111-1111-111111111111');
SELECT throws_ok($$SELECT body_map_figure FROM app.persons LIMIT 1$$, '42501', NULL,
  'Trainerin liest die Praeferenz ihrer Spielerinnen nicht, wie bei birth_date');
SELECT lives_ok($$SELECT display_name FROM app.persons LIMIT 1$$,
  'Der Rest der Kaderliste bleibt lesbar, es ist kein pauschaler Entzug');
SELECT throws_ok($$SELECT birth_date FROM app.persons LIMIT 1$$, '42501', NULL,
  'birth_date bleibt gesperrt (Bestandswahrung aus 08_reconciling.sql)');
RESET ROLE;

SET ROLE anon;
SELECT throws_ok($$SELECT app.rpc_my_body_map_figure()$$, '42501', NULL,
  'anon fuehrt den Leseweg nicht aus');
SELECT throws_ok($$SELECT app.rpc_set_my_body_map_figure('neutral')$$, '42501', NULL,
  'anon fuehrt den Schreibweg nicht aus');
RESET ROLE;

-- Ohne Claims gibt es keine eigene Person, also auch keine Praeferenz.
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '', true);
SELECT is((SELECT app.rpc_my_body_map_figure()),
  jsonb_build_object('code', '42501', 'message', 'FORBIDDEN: persons.body_map_figure', 'details', NULL, 'hint', NULL),
  'Ohne Claims FORBIDDEN');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
