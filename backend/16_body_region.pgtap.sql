-- =============================================================================
-- 16_body_region.pgtap.sql — Regionskatalog in der Datenbank (AP-43)
-- Voraussetzung: 08_reconciling.sql, 16_body_region.sql.
-- Laeuft in einer Transaktion und rollt zurueck, tpos_gate_test bleibt leer.
--
-- Der Kern dieser Suite ist Test 12: er liest backend/body_regions.json von der
-- Platte und stellt sie Zeile fuer Zeile gegen app.body_region. Solange er
-- gruen ist, kann die Tabelle nicht von der Datei abdriften, und die Datei
-- bleibt die Quelle. Deshalb muss psql aus dem Repo Wurzelverzeichnis laufen.
-- =============================================================================

\set ON_ERROR_STOP on
\set catalog `cat backend/body_regions.json`

BEGIN;
SET search_path = public, pgtap;
SELECT plan(30);

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------
SELECT has_table('app', 'body_region',         'app.body_region existiert');
SELECT has_table('app', 'body_standard_area',  'app.body_standard_area existiert');
SELECT has_table('app', 'body_region_group',   'app.body_region_group existiert');
SELECT has_table('app', 'body_figure_variant', 'app.body_figure_variant existiert');

SELECT col_is_pk('app', 'body_region', 'key', 'key ist der Primaerschluessel');
SELECT has_column('app', 'body_region', 'region_group',
  'group liegt als Spalte in der Tabelle (Entscheidung Chris 2026-09-21), nicht nur in der App');
SELECT has_column('app', 'body_region', 'active_to',
  'active_to ist der Abschalter fuer Altschluessel, ohne die Zeile zu verlieren');

-- ---------------------------------------------------------------------------
-- Zuschnitt: 23 Regionen, 17 seitengetrennt, 40 Schluessel, dazu 6 Altschluessel
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM app.body_region), 46, '46 Eintraege');
SELECT is((SELECT count(*)::int FROM app.body_region WHERE is_selectable), 40, '40 waehlbare Schluessel');
SELECT is((SELECT count(*)::int FROM app.body_region WHERE NOT is_selectable), 6,
  '6 Altschluessel ohne Flaeche, lesbar aber nicht waehlbar');
SELECT is((SELECT count(*)::int FROM app.body_standard_area), 18,
  '18 IOC Areale (Bahr et al., BJSM 2020, Tabelle 4)');
SELECT is((SELECT count(*)::int FROM app.body_region_group), 6, '6 Bereiche fuer die Listenansicht');
SELECT is((SELECT count(*)::int FROM app.body_figure_variant), 6,
  '6 Figurvarianten, drei Figuren mal vorne und hinten');

-- ---------------------------------------------------------------------------
-- Die Datei ist die Quelle
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _datei AS
SELECT r.key, r.label_de, r.side, r."lateral" AS lateral_side, r."group" AS region_group,
       r.standard_area, r.sort, r.active_from, r.standard_area_note, r.standard_area_open
  FROM jsonb_to_recordset((:'catalog')::jsonb -> 'regions')
       AS r(key text, label_de text, side text, "lateral" text, "group" text,
            standard_area text, sort integer, active_from date,
            standard_area_note text, standard_area_open text);

SELECT is((SELECT count(*)::int FROM _datei), 46, 'Die Datei selbst haelt 46 Eintraege');

SELECT set_eq(
  $$SELECT key, label_de, side, lateral_side, region_group, standard_area, sort,
           active_from, standard_area_note, standard_area_open FROM _datei$$,
  $$SELECT key, label_de, side, lateral_side, region_group, standard_area, sort,
           active_from, standard_area_note, standard_area_open FROM app.body_region$$,
  'Tabelle gleich Datei: alle 46 Zeilen in allen Feldern. Driftet eine der beiden ab, faellt dieser Test');

-- set_eq bekommt seine Abfragen als Zeichenkette, und psql ersetzt :'catalog'
-- innerhalb eines Literals nicht. Deshalb erst in Tabellen legen, dann vergleichen.
CREATE TEMP TABLE _datei_areale AS
SELECT a.key, a.value ->> 'ioc_area' AS ioc_area, a.value ->> 'ioc_region' AS ioc_region,
       a.value ->> 'osiics' AS osiics, a.value ->> 'smdcs' AS smdcs
  FROM jsonb_each((:'catalog')::jsonb #> '{_meta,standard_areas}') a;

CREATE TEMP TABLE _datei_bereiche AS
SELECT g.id, g.label_de, g.sort
  FROM jsonb_to_recordset((:'catalog')::jsonb #> '{_meta,groups}') AS g(id text, label_de text, sort integer);

CREATE TEMP TABLE _datei_figuren AS
SELECT v.key, v.figur, v.ansicht, v.sort
  FROM jsonb_to_recordset((:'catalog')::jsonb #> '{_meta,figure_variants}')
       AS v(key text, figur text, ansicht text, sort integer);

SELECT set_eq(
  $$SELECT key, ioc_area, ioc_region, osiics, smdcs FROM _datei_areale$$,
  $$SELECT key, ioc_area, ioc_region, osiics, smdcs FROM app.body_standard_area$$,
  'Die 18 Areale kommen aus der Datei, mit Code OSIICS und SMDCS');

SELECT set_eq(
  $$SELECT id, label_de, sort FROM _datei_bereiche$$,
  $$SELECT id, label_de, sort FROM app.body_region_group$$,
  'Die 6 Bereiche kommen aus der Datei');

SELECT set_eq(
  $$SELECT key, figur, ansicht, sort FROM _datei_figuren$$,
  $$SELECT key, figur, ansicht, sort FROM app.body_figure_variant$$,
  'Die 6 Figurvarianten kommen aus der Datei');

SELECT is(
  (SELECT (:'catalog')::jsonb #>> '{_meta,stichtag}'),
  '2026-09-21',
  'Stichtag ist 2026-09-21, der Platzhalter 2026-10-01 ist weg (Entscheidung Chris)');

-- ---------------------------------------------------------------------------
-- Zusagen, auf die sich die Pruefung in rpc_submit_checkin verlaesst
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM app.body_region WHERE active_to IS NOT NULL), 0,
  'Heute ist kein Schluessel abgeschaltet, auch die Altschluessel nicht');
SELECT is((SELECT count(*)::int FROM app.body_region WHERE is_selectable AND standard_area IS NULL), 0,
  'Jeder waehlbare Schluessel traegt sein IOC Areal');
SELECT is((SELECT count(*)::int FROM app.body_region
            WHERE standard_area IS NULL AND standard_area_open IS NULL), 0,
  'Kein Schluessel ohne Areal und ohne Begruendung. Offen ist dokumentiert, nicht geraten');
SELECT is((SELECT count(*)::int FROM app.body_region WHERE is_selectable AND region_group IS NULL), 0,
  'Jeder waehlbare Schluessel liegt in einem Bereich der Listenansicht');

-- ---------------------------------------------------------------------------
-- Grenzen der Tabelle
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO app.body_region (key, label_de, side, sort, active_from, standard_area)
    VALUES ('x_test', 'X', 'seitwaerts', 9999, current_date, 'knee')$$,
  '23514', NULL, 'side kennt nur front, back und both');

SELECT throws_ok(
  $$INSERT INTO app.body_region (key, label_de, side, lateral_side, region_group, sort, active_from, standard_area)
    VALUES ('x_test', 'X', 'front', 'links', 'fuss', 9999, current_date, 'knee')$$,
  '23514', NULL, 'lateral_side kennt nur l und r');

SELECT throws_ok(
  $$INSERT INTO app.body_region (key, label_de, side, region_group, sort, active_from, standard_area)
    VALUES ('x_test', 'X', 'front', 'fuss', 10, current_date, 'knee')$$,
  '23505', NULL, 'sort bleibt eindeutig, sonst waere die Reihenfolge der Liste nicht bestimmt');

SELECT throws_ok(
  $$INSERT INTO app.body_region (key, label_de, side, region_group, sort, active_from, standard_area)
    VALUES ('x_test', 'X', 'front', 'fuss', 9999, current_date, 'gibt_es_nicht')$$,
  '23503', NULL, 'standard_area zeigt nur auf ein bekanntes IOC Areal');

-- ---------------------------------------------------------------------------
-- Rechte: lesen ja, schreiben nein
-- ---------------------------------------------------------------------------
SET ROLE authenticated;
SELECT lives_ok($$SELECT count(*) FROM app.body_region$$,
  'authenticated liest den Katalog. Er traegt nichts Team-Eigenes und nichts ueber Personen');
SELECT throws_ok(
  $$INSERT INTO app.body_region (key, label_de, side, region_group, sort, active_from, standard_area)
    VALUES ('x_test', 'X', 'front', 'fuss', 9999, current_date, 'knee')$$,
  '42501', NULL, 'authenticated schreibt den Katalog nicht. Aenderungen kommen aus einer Migration');
RESET ROLE;

SET ROLE anon;
SELECT throws_ok($$SELECT count(*) FROM app.body_region$$, '42501', NULL,
  'anon sieht den Katalog nicht, wie alles in app seit Migration 20260921000024');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
