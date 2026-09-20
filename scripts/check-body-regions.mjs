// Prüft backend/body_regions.json (AP-43a). Aufruf: node scripts/check-body-regions.mjs
// Kein Netzwerk, keine Abhängigkeiten. Exit 1 bei jedem Fehler.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const catalogPath = resolve(here, '../backend/body_regions.json');
const playerEditor = resolve(here, '../../team-performance-os-player/src/components/BodyMapEditor.tsx');

// Die 19 Schlüssel der Chipliste im Player (Stand vor Block C). Bleiben unangetastet.
const LEGACY_19 = [
  'nacken', 'schulter_l', 'schulter_r', 'oberarm_l', 'oberarm_r', 'ellbogen_unterarm_l', 'ellbogen_unterarm_r',
  'hand_l', 'hand_r', 'brust', 'ruecken_oberruecken', 'lws_kreuz', 'huefte', 'knie_l', 'knie_r',
  'wade_l', 'wade_r', 'fuss_l', 'fuss_r',
];
const EXPECT = { keys: 40, regions: 23, lateralRegions: 17, legacyOnly: 6 };

const errors = [];
const fail = (msg) => errors.push(msg);

let doc;
try {
  doc = JSON.parse(readFileSync(catalogPath, 'utf8'));
} catch (e) {
  console.error(`FEHLER: ${catalogPath} nicht lesbar: ${e.message}`);
  process.exit(1);
}

const meta = doc._meta ?? {};
const quelle = doc._quelle ?? {};
const regions = Array.isArray(doc.regions) ? doc.regions : [];
if (!regions.length) fail('regions fehlt oder ist leer');
for (const f of ['titel', 'doi', 'stelle', 'abgerufen']) if (!quelle[f]) fail(`_quelle.${f} fehlt`);
if (quelle.abgerufen && !/^\d{4}-\d{2}-\d{2}$/.test(quelle.abgerufen)) fail('_quelle.abgerufen ist kein ISO Datum');
if (!meta.stichtag || !meta.legacy_active_from) fail('_meta.stichtag oder _meta.legacy_active_from fehlt');
const areas = meta.standard_areas ?? {};
const groups = new Set((meta.groups ?? []).map((g) => g.id));

const FIELDS = ['key', 'label_de', 'side', 'lateral', 'standard_area', 'sort', 'active_from'];
const keys = new Set();
const sorts = new Set();
const isActive = (r) => r.side !== null;

for (const r of regions) {
  const id = r?.key ?? '(ohne key)';
  for (const f of FIELDS) if (!(f in r)) fail(`${id}: Feld ${f} fehlt`);
  if (typeof r.key !== 'string' || !/^[a-z]+(_[a-z]+)*$/.test(r.key)) fail(`${id}: key nicht klein, deutsch, mit Unterstrich`);
  if (keys.has(r.key)) fail(`${id}: key doppelt`);
  keys.add(r.key);
  if (!Number.isInteger(r.sort)) fail(`${id}: sort ist keine ganze Zahl`);
  else if (sorts.has(r.sort)) fail(`${id}: sort ${r.sort} doppelt`);
  else sorts.add(r.sort);
  if (![null, 'front', 'back', 'both'].includes(r.side)) fail(`${id}: side ${r.side} ungültig`);
  if (![null, 'l', 'r'].includes(r.lateral)) fail(`${id}: lateral ${r.lateral} ungültig`);
  const suffix = /_(l|r)$/.exec(r.key)?.[1] ?? null;
  if (suffix !== r.lateral) fail(`${id}: lateral ${r.lateral} passt nicht zum Suffix ${suffix}`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(r.active_from ?? '')) fail(`${id}: active_from kein ISO Datum`);
  if (/[-‐-―]/.test(r.label_de ?? '')) fail(`${id}: label_de enthält einen Bindestrich (Regel: keine Bindestriche in UI Copy)`);
  if (!r.label_de?.trim()) fail(`${id}: label_de leer`);

  if (isActive(r)) {
    if (!r.standard_area) fail(`${id}: aktiver Schlüssel ohne standard_area`);
    else if (!areas[r.standard_area]) fail(`${id}: standard_area ${r.standard_area} steht nicht im IOC Vokabular (_meta.standard_areas)`);
    if (!groups.has(r.group)) fail(`${id}: group ${r.group} unbekannt`);
    if (r.standard_area_open) fail(`${id}: aktiver Schlüssel darf nicht als offen markiert sein`);
  } else {
    if (r.group !== null) fail(`${id}: Altschlüssel ohne Fläche muss group null haben`);
    if (r.active_from >= meta.stichtag) fail(`${id}: Altschlüssel muss vor dem Stichtag beginnen`);
    if (r.standard_area === null && !r.standard_area_open) fail(`${id}: standard_area null ohne Begründung in standard_area_open (offen markieren, nicht raten)`);
    if (r.standard_area !== null && !areas[r.standard_area]) fail(`${id}: standard_area ${r.standard_area} unbekannt`);
  }
}

// Seitengetrennte Regionen haben genau l und r. Einträge ohne Seite sind je eine eigene Region.
// (Der Altschlüssel "huefte" ohne Seite und die neue Region "huefte" mit l und r sind verschiedene Dinge.)
const regionId = (r) => (r.lateral ? `seiten:${r.key.replace(/_(l|r)$/, '')}` : `eins:${r.key}`);
const byRegion = new Map();
for (const r of regions) {
  const id = regionId(r);
  if (!byRegion.has(id)) byRegion.set(id, []);
  byRegion.get(id).push(r);
}
for (const [id, list] of byRegion) {
  if (id.startsWith('seiten:')) {
    const lat = list.map((r) => r.lateral).sort().join('');
    if (lat !== 'lr') fail(`${id.slice(7)}: seitengetrennt, aber vorhandene Seiten sind "${lat}" statt "lr"`);
    if (new Set(list.map((r) => r.side)).size !== 1) fail(`${id.slice(7)}: links und rechts haben unterschiedliche side`);
  } else if (list.length !== 1) {
    fail(`${id.slice(5)}: ohne Seite, aber ${list.length} Einträge`);
  }
}

// Zuschnitt aus Modul-Body-Map Abschnitt 6
const active = regions.filter(isActive);
const activeBases = new Set(active.map(regionId));
const lateralBases = new Set(active.filter((r) => r.lateral).map(regionId));
if (active.length !== EXPECT.keys) fail(`${active.length} aktive Schlüssel, erwartet ${EXPECT.keys}`);
if (activeBases.size !== EXPECT.regions) fail(`${activeBases.size} aktive Regionen, erwartet ${EXPECT.regions}`);
if (lateralBases.size !== EXPECT.lateralRegions) fail(`${lateralBases.size} seitengetrennte Regionen, erwartet ${EXPECT.lateralRegions}`);
if (regions.length - active.length !== EXPECT.legacyOnly) fail(`${regions.length - active.length} Altschlüssel ohne Nachfolger, erwartet ${EXPECT.legacyOnly}`);

// Die 19 Altschlüssel sind vollständig da, und es gibt keinen Altschlüssel mit neuem Datum
for (const k of LEGACY_19) if (!keys.has(k)) fail(`Altschlüssel ${k} fehlt im Katalog`);
for (const r of regions) {
  const legacy = LEGACY_19.includes(r.key);
  if (legacy && r.active_from !== meta.legacy_active_from) fail(`${r.key}: Altschlüssel muss active_from ${meta.legacy_active_from} tragen`);
  if (!legacy && r.active_from !== meta.stichtag) fail(`${r.key}: neuer Schlüssel muss active_from ${meta.stichtag} tragen`);
}

// Altliste im Player gegen die feste Liste oben prüfen, falls das Repo daneben liegt
if (existsSync(playerEditor)) {
  const src = readFileSync(playerEditor, 'utf8');
  const found = [...src.matchAll(/\{ key: '([a-z_]+)', label:/g)].map((m) => m[1]).sort();
  if (found.join() !== [...LEGACY_19].sort().join()) fail(`BodyMapEditor.tsx enthält andere Schlüssel als die feste Liste der 19 (${found.length} gefunden)`);
}

const open = regions.filter((r) => r.standard_area_open);
const seiten = { front: 0, back: 0, both: 0 };
for (const r of active) seiten[r.side]++;
console.log(`Katalog: ${regions.length} Einträge, ${active.length} aktive Schlüssel in ${activeBases.size} Regionen (${lateralBases.size} seitengetrennt), ${regions.length - active.length} Altschlüssel ohne Nachfolger`);
console.log(`Seiten (aktive Schlüssel): nur vorne ${seiten.front}, nur hinten ${seiten.back}, beide ${seiten.both}`);
console.log(`Quelle: ${quelle.stelle} (${quelle.doi}), abgerufen ${quelle.abgerufen}`);
if (open.length) console.log(`OFFEN (standard_area nicht zuweisbar): ${open.map((r) => r.key).join(', ')}`);

if (errors.length) {
  console.error(`\n${errors.length} Fehler:`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log('check-body-regions: OK');
