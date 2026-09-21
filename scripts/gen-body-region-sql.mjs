#!/usr/bin/env node
// =============================================================================
// gen-body-region-sql.mjs — traegt backend/body_regions.json in
// backend/16_body_region.sql ein (AP-43).
//
// Die Katalogdatei ist die Quelle. Die Migration braucht denselben Inhalt in
// SQL. Statt 46 Zeilen von Hand abzutippen, setzt dieses Skript die Datei
// woertlich als jsonb in die Funktion app.body_region_catalog() und die INSERTs
// lesen sie von dort. Damit gibt es genau eine Stelle, an der Zuschnitt und
// Beschriftung stehen.
//
// Aufruf:  node scripts/gen-body-region-sql.mjs
//          node scripts/gen-body-region-sql.mjs --check   (nur pruefen, CI)
//
// Der Block zwischen den beiden Markern wird ersetzt, alles andere in der
// SQL Datei bleibt unangetastet und wird von Hand gepflegt.
// =============================================================================

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const catalogPath = join(root, 'backend', 'body_regions.json');
const sqlPath = join(root, 'backend', '16_body_region.sql');

const START = '-- >>> GENERIERT AUS backend/body_regions.json — NICHT VON HAND AENDERN';
const END = '-- <<< ENDE GENERIERT';

const checkOnly = process.argv.includes('--check');

const raw = readFileSync(catalogPath, 'utf8');
const doc = JSON.parse(raw);
if (!Array.isArray(doc.regions) || !doc.regions.length) {
  console.error('FEHLER: regions fehlt oder ist leer');
  process.exit(1);
}

// Dollar Quoting: der Katalog enthaelt einfache und doppelte Anfuehrungszeichen
// (standard_area_note zitiert die Quelle), deshalb kein '...' Literal. Das Tag
// darf im Inhalt nicht vorkommen, sonst bricht das Literal auf.
const TAG = '$bodyregions$';
if (raw.includes(TAG)) {
  console.error(`FEHLER: der Katalog enthaelt ${TAG}, das Dollar Quoting waere kaputt`);
  process.exit(1);
}

// Kompakt einsetzen, eine Zeile je Region. Die Datei bleibt die lesbare Form,
// die SQL Datei soll nur die Werte tragen.
const compact = JSON.stringify(doc);

const block = [
  START,
  '-- Erzeugt von scripts/gen-body-region-sql.mjs. Aenderungen gehoeren in',
  `-- backend/body_regions.json, danach das Skript erneut laufen lassen.`,
  `-- Stand der Quelle: ${doc.regions.length} Eintraege, Stichtag ${doc._meta?.stichtag}.`,
  'CREATE OR REPLACE FUNCTION app.body_region_catalog()',
  'RETURNS jsonb',
  'LANGUAGE sql',
  'IMMUTABLE',
  'AS $fn$',
  `  SELECT ${TAG}${compact}${TAG}::jsonb;`,
  '$fn$;',
  END,
].join('\n');

const sql = readFileSync(sqlPath, 'utf8');
const startAt = sql.indexOf(START);
const endAt = sql.indexOf(END);
if (startAt < 0 || endAt < 0 || endAt < startAt) {
  console.error(`FEHLER: Marker in ${sqlPath} nicht gefunden`);
  process.exit(1);
}

const next = sql.slice(0, startAt) + block + sql.slice(endAt + END.length);

if (next === sql) {
  console.log('gen-body-region-sql: unveraendert');
  process.exit(0);
}

if (checkOnly) {
  console.error('FEHLER: backend/16_body_region.sql passt nicht zu backend/body_regions.json.');
  console.error('        node scripts/gen-body-region-sql.mjs ausfuehren und committen.');
  process.exit(1);
}

writeFileSync(sqlPath, next);
console.log(`gen-body-region-sql: ${doc.regions.length} Regionen, ` +
  `${Object.keys(doc._meta?.standard_areas ?? {}).length} Areale, ` +
  `${(doc._meta?.groups ?? []).length} Bereiche, ` +
  `${(doc._meta?.figure_variants ?? []).length} Figurvarianten in backend/16_body_region.sql`);
