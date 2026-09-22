#!/usr/bin/env node
// Team Performance OS — AP-45d: haelt der Vertrag aus Option A ueber PostgREST?
//
// Frage: wendet die gehostete PostgREST set_config('response.status','403',true) an?
// Lokal ist das nicht messbar, es laeuft kein PostgREST (kein Docker). Der Rest des
// Vertrags ist lokal belegt (Autocommit Messung, pgTAP Suite 20).
//
// Aufruf:  node scripts/ap45d-denial-probe.mjs --check
//
// Was das Skript tut:
//   1. Service Key aus `supabase projects api-keys` in eine Variable, nie in eine Datei.
//   2. Admin generate_link (magiclink) fuer den Trainer. Verschickt KEINE Mail.
//   3. POST /auth/v1/verify liefert eine echte Sitzung.
//   4. Ein Aufruf von public.rpc_my_body_map_history mit diesem Token. Der Trainer
//      ist kein player, die Tuer lehnt ab.
//   5. Zaehlt app.access_denials vorher und nachher ueber den Service Key.
//   6. Meldet die Sitzung wieder ab (scope=local).
//
// Nebenwirkung, von Chris am 2026-09-22 im Chat freigegeben: app.access_denials
// waechst um genau eine Zeile (Trainer, daily_checkins.body_map). auth.sessions
// waechst um eins und wird am Ende beendet. Keine Gesundheitsdaten werden beruehrt.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const COACH_EMAIL = "coach@c-klan.de";

if (process.argv[2] !== "--check") {
  console.error("Aufruf: node scripts/ap45d-denial-probe.mjs --check");
  process.exit(2);
}

const env = Object.fromEntries(
  readFileSync(join(ROOT, ".env.local"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const BASE = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

const keys = JSON.parse(
  execFileSync("supabase", ["projects", "api-keys", "--project-ref", REF, "-o", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }),
);
const serviceKey = keys.find((k) => k.name === "service_role" || k.id === "service_role")?.api_key;
if (!serviceKey) throw new Error("service key nicht gefunden");

let failed = false;
const check = (name, ok, detail = "") => {
  if (!ok) failed = true;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
};

const svc = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" };

async function denialCount() {
  const r = await fetch(`${BASE}/rest/v1/rpc/_ap45d_count_denials`, { method: "POST", headers: svc, body: "{}" });
  if (r.ok) return Number(await r.json());
  return null;
}

// Zaehlen ohne neue Funktion: app ist fuer die API zu, also ueber die Tabelle in app
// geht es nicht. Wir zaehlen deshalb mit dem CLI, lesend.
function countViaCli() {
  const out = execFileSync("supabase", ["db", "query", "--linked", "select count(*) as n from app.access_denials"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const i = out.indexOf("{");
  return Number(JSON.parse(out.slice(i)).rows[0].n);
}

const vorher = countViaCli();
console.log(`app.access_denials vorher: ${vorher}`);

const linkRes = await fetch(`${BASE}/auth/v1/admin/generate_link`, {
  method: "POST",
  headers: svc,
  body: JSON.stringify({ type: "magiclink", email: COACH_EMAIL }),
});
const link = await linkRes.json();
check("generate_link fuer den Trainer", linkRes.ok && Boolean(link.hashed_token), `HTTP ${linkRes.status}`);
if (!link.hashed_token) process.exit(1);

const verifyRes = await fetch(`${BASE}/auth/v1/verify`, {
  method: "POST",
  headers: { apikey: ANON, "Content-Type": "application/json" },
  body: JSON.stringify({ type: "magiclink", token_hash: link.hashed_token }),
});
const session = await verifyRes.json();
check("verify liefert eine Sitzung", verifyRes.ok && Boolean(session.access_token), `HTTP ${verifyRes.status}`);
if (!session.access_token) process.exit(1);

const claims = JSON.parse(Buffer.from(session.access_token.split(".")[1], "base64url").toString("utf8"));
check("JWT traegt app_role coach", claims.app_role === "coach", `app_role ${claims.app_role ?? "-"}`);

const auth = { apikey: ANON, Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" };

const res = await fetch(`${BASE}/rest/v1/rpc/rpc_my_body_map_history`, {
  method: "POST",
  headers: auth,
  body: JSON.stringify({ p_days: 28 }),
});
const body = await res.text();
let parsed = null;
try { parsed = JSON.parse(body); } catch { /* egal */ }

console.log(`\nAntwort der Tuer: HTTP ${res.status}`);
console.log(`Body: ${body.slice(0, 200)}`);

check("HTTP Status ist 403", res.status === 403, `ist ${res.status}`);
check("code ist 42501", parsed?.code === "42501", String(parsed?.code));
check("message ist FORBIDDEN: daily_checkins.body_map",
  parsed?.message === "FORBIDDEN: daily_checkins.body_map", String(parsed?.message));
check("details und hint sind null", parsed?.details === null && parsed?.hint === null);

await fetch(`${BASE}/auth/v1/logout?scope=local`, { method: "POST", headers: auth });
console.log("Sitzung abgemeldet (scope=local)");

const nachher = countViaCli();
console.log(`app.access_denials nachher: ${nachher}`);
check("Die Ablehnung hat den Commit ueberlebt", nachher === vorher + 1, `${vorher} -> ${nachher}`);

process.exit(failed ? 1 : 0);
