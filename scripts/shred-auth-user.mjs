#!/usr/bin/env node
// Team Performance OS — AP-39b Schritt 8: Auth Konto nach dem Shred loeschen
//
// app.rpc_shred_person raeumt alles, was in der Datenbank liegt, und gibt die alte
// auth_user_id zurueck. Das Auth Konto selbst liegt im Schema `auth` und wird nicht
// per SQL geloescht, sondern ueber die Supabase Admin API. Ohne diesen zweiten
// Schritt bliebe die E-Mail Adresse gespeichert und machte das Pseudonym in
// app.persons wieder aufloesbar (Entscheidung 4 von Chris, 2026-09-21).
//
// Aufruf:
//   node scripts/shred-auth-user.mjs <auth_user_id>             Probelauf, loescht nichts
//   node scripts/shred-auth-user.mjs <auth_user_id> --confirm   loescht das Konto
//
// Der Probelauf ist der Standard, und das mit Absicht: ein geloeschtes Auth Konto
// kommt nicht zurueck. Das Skript wurde am 2026-09-21 gebaut und bewusst NICHT
// ausgefuehrt.
//
// Zwei Sicherungen, bevor etwas geloescht wird:
//   1. Es darf keine Zeile in app.persons mehr auf diese auth_user_id zeigen.
//      Zeigt noch eine darauf, ist der Shred in der Datenbank nicht gelaufen, und
//      das Konto zu loeschen wuerde eine Person vom Login trennen, deren Daten
//      noch da sind. Das Skript bricht dann ab.
//   2. Es muss eine Abschlusszeile im app.audit_log geben, die belegt, dass ein
//      Shred stattgefunden hat.
//
// Der Service Key bleibt im Speicher und wird nie ausgegeben. Ausgegeben werden
// nur die uuid, Zeilenzahlen und PASS oder FAIL, keine E-Mail Adresse.
//
// Erlaubnisregel fuer Claude Code: "Bash(node scripts/shred-auth-user.mjs *)".
// Sie ist bisher NICHT gesetzt, das ist beabsichtigt.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const authUserId = process.argv[2];
const confirmed = process.argv.includes("--confirm");

if (!authUserId || !UUID_RE.test(authUserId)) {
  console.error("Aufruf: node scripts/shred-auth-user.mjs <auth_user_id> [--confirm]");
  console.error("Die auth_user_id ist der Rueckgabewert von app.rpc_shred_person.");
  process.exit(2);
}

const env = Object.fromEntries(
  readFileSync(join(ROOT, ".env.local"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const BASE = env.NEXT_PUBLIC_SUPABASE_URL;
if (!BASE) throw new Error("NEXT_PUBLIC_SUPABASE_URL fehlt in .env.local");

function dbQuery(sql) {
  const out = execFileSync("supabase", ["db", "query", "--linked", sql, "-o", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const start = out.indexOf("{");
  return JSON.parse(out.slice(start)).rows ?? [];
}

// ---------------------------------------------------------------------------
// Sicherung 1 und 2: der Shred in der Datenbank muss gelaufen sein
// ---------------------------------------------------------------------------

const [state] = dbQuery(
  `select (select count(*) from app.persons where auth_user_id = '${authUserId}') as noch_verknuepft,
          (select count(*) from app.audit_log
            where table_name = 'persons' and new_row ->> 'action' = 'crypto_shred') as abschlusszeilen;`,
);

const stillLinked = Number(state?.noch_verknuepft ?? -1);
const shredRows = Number(state?.abschlusszeilen ?? 0);

console.log(`auth_user_id            ${authUserId}`);
console.log(`noch verknuepft in app.persons   ${stillLinked}`);
console.log(`Abschlusszeilen im audit_log     ${shredRows}`);
console.log("");

if (stillLinked !== 0) {
  console.error("ABBRUCH: es zeigt noch eine Zeile in app.persons auf diese auth_user_id.");
  console.error("Der Shred in der Datenbank ist nicht gelaufen. Erst app.rpc_shred_person aufrufen.");
  process.exit(1);
}
if (shredRows === 0) {
  console.error("ABBRUCH: im audit_log steht keine Abschlusszeile eines Shreds.");
  console.error("Ohne diesen Nachweis wird hier kein Konto geloescht.");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Das Konto
// ---------------------------------------------------------------------------

const keys = JSON.parse(
  execFileSync("supabase", ["projects", "api-keys", "--project-ref", REF, "-o", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }),
);
const serviceKey = keys.find((k) => k.name === "service_role" || k.id === "service_role")?.api_key;
if (!serviceKey) throw new Error("service key nicht gefunden");

const admin = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

const lookup = await fetch(`${BASE}/auth/v1/admin/users/${authUserId}`, { headers: admin });
if (lookup.status === 404) {
  console.log("Das Konto gibt es nicht mehr. Nichts zu tun.");
  process.exit(0);
}
if (!lookup.ok) {
  console.error(`ABBRUCH: Konto nicht lesbar (HTTP ${lookup.status}).`);
  process.exit(1);
}
console.log("Das Konto existiert und ist zum Loeschen bereit.");

if (!confirmed) {
  console.log("");
  console.log("PROBELAUF, es wurde nichts geloescht.");
  console.log(`Zum Loeschen: node scripts/shred-auth-user.mjs ${authUserId} --confirm`);
  process.exit(0);
}

// `should_soft_delete` ist bewusst nicht gesetzt: ein weich geloeschtes Konto
// behielte die E-Mail Adresse, und genau die soll verschwinden.
const del = await fetch(`${BASE}/auth/v1/admin/users/${authUserId}`, {
  method: "DELETE",
  headers: { ...admin, "Content-Type": "application/json" },
  body: JSON.stringify({ should_soft_delete: false }),
});

if (!del.ok) {
  console.error(`FAIL: Loeschen fehlgeschlagen (HTTP ${del.status}).`);
  process.exit(1);
}

const after = await fetch(`${BASE}/auth/v1/admin/users/${authUserId}`, { headers: admin });
console.log(after.status === 404
  ? "PASS: Konto geloescht, ein erneutes Lesen findet es nicht mehr."
  : `FAIL: Konto nach dem Loeschen weiter lesbar (HTTP ${after.status}).`);
process.exit(after.status === 404 ? 0 : 1);
