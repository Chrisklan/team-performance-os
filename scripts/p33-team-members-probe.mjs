#!/usr/bin/env node
// Team Performance OS — Bridge Punkt 33/44/64: haelt die Tuer rpc_list_team_members in der Cloud,
// und kommt "nicht gefunden" als HTTP 404 heraus?
//
// Aufruf:  node scripts/p33-team-members-probe.mjs --check
// Erst NACH der Einspielung von 20260923000043_team_members_door und nur mit Freigabe von Chris.
//
// Was das Skript tut (Ablauf wie scripts/ap47a-medical-doors-probe.mjs):
//   1. Service Key aus `supabase projects api-keys` in eine Variable, nie in eine Datei.
//   2. Admin generate_link (magiclink) fuer die Physio. Verschickt KEINE Mail.
//   3. POST /auth/v1/verify liefert eine echte Sitzung.
//   4. Die Liste einmal mit anon Schluessel, einmal mit Physio JWT, dazu
//      rpc_review_deviation mit einer unbekannten ID. Zaehler vor und nach jedem Aufruf.
//   5. Meldet die Sitzung wieder ab (scope=local).
//
// Nebenwirkung: KEINE Datenzeile. Die Liste schreibt kein access_log, die unbekannte
// Abweichung ist ein Sachfehler (kein access_denials). Nur auth.sessions waechst um
// eins und wird am Ende beendet. Die Detail-Tueren werden bewusst NICHT gerufen,
// sie wuerden vier Zeilen in die Zugriffsuebersicht einer echten Person schreiben.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const PHYSIO_EMAIL = "physio@c-klan.de";

if (process.argv[2] !== "--check") {
  console.error("Aufruf: node scripts/p33-team-members-probe.mjs --check");
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

function q(sql) {
  const out = execFileSync("supabase", ["db", "query", "--linked", sql], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return JSON.parse(out.slice(out.indexOf("{"))).rows;
}
const zaehler = () =>
  q("select (select count(*) from app.access_log) as log, (select count(*) from app.access_denials) as deny")[0];

async function rpc(name, body, headers) {
  const vor = zaehler();
  const res = await fetch(`${BASE}/rest/v1/rpc/${name}`, { method: "POST", headers, body: JSON.stringify(body) });
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* egal */ }
  const nach = zaehler();
  const delta = { log: nach.log - vor.log, deny: nach.deny - vor.deny };
  // Die Liste traegt Namen: nicht ausgeben, nur zaehlen.
  console.log(`\n--- ${name} — HTTP ${res.status}, Delta log ${delta.log}, deny ${delta.deny}`);
  return { status: res.status, parsed, delta };
}

// 0 anon Schluessel: die Tuer ist fuer anon zu
let r = await rpc("rpc_list_team_members", {}, { apikey: ANON, Authorization: `Bearer ${ANON}`, "Content-Type": "application/json" });
check("0 anon bekommt keine Liste", r.status === 401 || r.status === 403, `HTTP ${r.status} ${r.parsed?.code ?? ""}`);
check("0 anon: code 42501", r.parsed?.code === "42501", String(r.parsed?.code));

// Sitzung
const linkRes = await fetch(`${BASE}/auth/v1/admin/generate_link`, {
  method: "POST",
  headers: svc,
  body: JSON.stringify({ type: "magiclink", email: PHYSIO_EMAIL }),
});
const link = await linkRes.json();
check("generate_link fuer die Physio", linkRes.ok && Boolean(link.hashed_token), `HTTP ${linkRes.status}`);
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
check("JWT traegt app_role physio", claims.app_role === "physio", `app_role ${claims.app_role ?? "-"}`);
const auth = { apikey: ANON, Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" };

// 1 Liste mit Physio JWT
r = await rpc("rpc_list_team_members", {}, auth);
const members = Array.isArray(r.parsed?.members) ? r.parsed.members : null;
check("1 Liste antwortet mit 200", r.status === 200, `HTTP ${r.status}`);
check("1 Antwort traegt members", members !== null);
check("1 keine access_log Zeile", r.delta.log === 0, `${r.delta.log}`);
check("1 keine access_denials Zeile", r.delta.deny === 0, `${r.delta.deny}`);
const keySets = new Set((members ?? []).map((m) => Object.keys(m).sort().join(",")));
check("1 genau vier Schluessel je Person", keySets.size === 1 && keySets.has("clearance_status,display_name,id,person_position"), [...keySets].join(" | "));
const ids = (members ?? []).map((m) => m.id);
const expected = q(
  "select count(*) as n from app.persons p where p.is_active and exists (select 1 from app.role_assignments ra " +
    "where ra.person_id = p.id and ra.team_id = p.team_id and ra.role = 'player' and ra.valid_from <= now() " +
    `and (ra.valid_to is null or ra.valid_to > now())) and p.team_id = '${claims.team_id}'`,
)[0].n;
check("1 Anzahl = aktive Spielerinnen des Teams", ids.length === Number(expected), `${ids.length} gegen ${expected}`);
check("1 keine Person doppelt", new Set(ids).size === ids.length);
const physioPerson = q(`select id::text from app.persons where auth_user_id = '${claims.sub}'`)[0]?.id;
check("1 die Physio selbst steht nicht in der Liste", !ids.includes(physioPerson));

// 2 Punkt 64: unbekannte Abweichung ist 404, nicht 500
r = await rpc("rpc_review_deviation", { p_deviation_id: "00000000-0000-0000-0000-0000000000ff", p_decision: "release" }, auth);
check("2 unbekannte Abweichung antwortet mit HTTP 404", r.status === 404, `HTTP ${r.status}`);
check("2 code ist P0002", r.parsed?.code === "P0002", String(r.parsed?.code));
check("2 nichts gewachsen", r.delta.log === 0 && r.delta.deny === 0, `log ${r.delta.log}, deny ${r.delta.deny}`);

// Positivkontrolle: eine alte Tuer, unveraendert erreichbar
const pk = await fetch(`${BASE}/rest/v1/rpc/rpc_my_body_map_figure`, { method: "POST", headers: auth, body: "{}" });
check("Positivkontrolle rpc_my_body_map_figure 200", pk.status === 200, `HTTP ${pk.status}`);

await fetch(`${BASE}/auth/v1/logout?scope=local`, { method: "POST", headers: auth });
console.log("\nSitzung abgemeldet (scope=local)");
process.exit(failed ? 1 : 0);
