#!/usr/bin/env node
// Team Performance OS — Einmal-Anmeldelink fuer eine Web-Sitzung ohne Passwort
// (Bridge Punkt 78, Muster wie scripts/ap47a-medical-doors-probe.mjs / sim-login.mjs).
//
// Aufruf: node scripts/ap78-web-login-link.mjs <email>
//
// Was das Skript tut:
//   1. Service Key aus `supabase projects api-keys` in eine Variable, nie in eine Datei.
//   2. Admin generate_link (magiclink) fuer die angegebene Adresse, redirect_to
//      http://localhost:3000/auth/callback (dev server muss laufen).
//   3. Gibt genau den Einmal-Link aus, sonst nichts. Kein Passwort, kein Service Key
//      im Output.
//
// Der Link ist einmal gueltig und lauft nach kurzer Zeit ab. Oeffnen im Browser
// setzt eine echte Supabase-Sitzung (Cookies ueber /auth/callback), genau wie ein
// echter Login per Mail.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const REDIRECT = "http://localhost:3000/auth/callback";

const email = process.argv[2];
if (!email) {
  console.error("Aufruf: node scripts/ap78-web-login-link.mjs <email>");
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

const keys = JSON.parse(
  execFileSync("supabase", ["projects", "api-keys", "--project-ref", REF, "-o", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }),
);
const serviceKey = keys.find((k) => k.name === "service_role" || k.id === "service_role")?.api_key;
if (!serviceKey) throw new Error("service key nicht gefunden");

const res = await fetch(`${BASE}/auth/v1/admin/generate_link`, {
  method: "POST",
  headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
  body: JSON.stringify({ type: "magiclink", email, redirect_to: REDIRECT }),
});
const body = await res.json();
if (!res.ok || !body.action_link) {
  console.error(`FAIL generate_link  HTTP ${res.status}`);
  process.exit(1);
}
console.log(body.action_link);
