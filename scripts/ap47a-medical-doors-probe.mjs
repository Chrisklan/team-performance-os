#!/usr/bin/env node
// Team Performance OS — AP-47a: halten die sechs Medizin-Tueren in der Cloud?
//
// Aufruf:  node scripts/ap47a-medical-doors-probe.mjs --check
//
// Was das Skript tut:
//   1. Service Key aus `supabase projects api-keys` in eine Variable, nie in eine Datei.
//   2. Admin generate_link (magiclink) fuer die Physio. Verschickt KEINE Mail.
//   3. POST /auth/v1/verify liefert eine echte Sitzung.
//   4. Die sechs Tueren je einmal, mit Zaehlerstand vor und nach jedem Aufruf.
//   5. Meldet die Sitzung wieder ab (scope=local).
//
// Nebenwirkung, von Chris am 2026-09-22 freigegeben: app.access_log waechst um die
// erlaubten Zugriffe, app.access_denials um die Ablehnung, app.clearance_proposals
// um eine Testzeile. auth.sessions waechst um eins und wird am Ende beendet.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const PHYSIO_EMAIL = "physio@c-klan.de";
const PHYSIO_PERSON = "a0000000-0000-0000-0000-000000000022";
const ZIEL_PERSON = "a0000000-0000-0000-0000-000000000005"; // Felix Becker, aktiv, eigenes Team

const MODUS = process.argv[2];
if (MODUS !== "--check" && MODUS !== "--nur-tuer4") {
  console.error("Aufruf: node scripts/ap47a-medical-doors-probe.mjs --check | --nur-tuer4");
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

// app ist fuer die API zu, also lesend ueber das CLI zaehlen.
function q(sql) {
  const out = execFileSync("supabase", ["db", "query", "--linked", sql], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return JSON.parse(out.slice(out.indexOf("{"))).rows;
}
const zaehler = () =>
  q(
    "select (select count(*) from app.access_log) as log, (select count(*) from app.access_denials) as deny, " +
      "(select count(*) from app.clearance_proposals) as vorschlaege, (select count(*) from app.medical_clearances) as freigaben",
  )[0];
const letzteLogZeile = () =>
  q("select subject_id::text as subject, actor_id::text as actor, action::text as action, resource from app.access_log order by occurred_at desc, id desc limit 1")[0];

// --- Sitzung ---
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
check("JWT traegt einen team_id Claim", Boolean(claims.team_id), `team_id ${claims.team_id ?? "-"}`);

const auth = { apikey: ANON, Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" };

async function tuer(name, body) {
  const vor = zaehler();
  const res = await fetch(`${BASE}/rest/v1/rpc/${name}`, { method: "POST", headers: auth, body: JSON.stringify(body) });
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* egal */ }
  const nach = zaehler();
  const delta = {
    log: nach.log - vor.log,
    deny: nach.deny - vor.deny,
    vorschlaege: nach.vorschlaege - vor.vorschlaege,
    freigaben: nach.freigaben - vor.freigaben,
  };
  console.log(`\n--- ${name} — HTTP ${res.status}`);
  console.log(`    Body:  ${text.slice(0, 220)}`);
  console.log(`    Delta: log ${delta.log}, deny ${delta.deny}, vorschlaege ${delta.vorschlaege}, freigaben ${delta.freigaben}`);
  return { status: res.status, parsed, text, delta };
}

let r;
if (MODUS === "--check") {
// 1 lesend, erlaubt
r = await tuer("rpc_medical_checkins", { p_person_id: ZIEL_PERSON, p_from: null, p_to: null });
check("1 rpc_medical_checkins antwortet mit 200", r.status === 200, `HTTP ${r.status}`);
check("1 keine Ablehnung im Rumpf", r.parsed?.error !== true && r.parsed?.code !== "42501");
check("1 genau eine access_log Zeile", r.delta.log === 1, `${r.delta.log}`);
let z = letzteLogZeile();
check("1 subject_id ist die GELESENE Person", z.subject === ZIEL_PERSON, `subject ${z.subject}`);
check("1 actor ist die Physio", z.actor === PHYSIO_PERSON, `actor ${z.actor}`);

// 2 lesend, erlaubt
r = await tuer("rpc_medical_readiness", { p_person_id: ZIEL_PERSON, p_from: null, p_to: null });
check("2 rpc_medical_readiness antwortet mit 200", r.status === 200, `HTTP ${r.status}`);
check("2 genau eine access_log Zeile", r.delta.log === 1, `${r.delta.log}`);
z = letzteLogZeile();
check("2 subject_id ist die GELESENE Person", z.subject === ZIEL_PERSON, `subject ${z.subject}`);

// 3 lesend, erlaubt
r = await tuer("rpc_get_clearance", { p_person_id: ZIEL_PERSON });
check("3 rpc_get_clearance antwortet mit 200", r.status === 200, `HTTP ${r.status}`);
check("3 Medizin sieht open_proposals", r.parsed !== null && "open_proposals" in (r.parsed ?? {}), Object.keys(r.parsed ?? {}).join(","));
check("3 genau eine access_log Zeile", r.delta.log === 1, `${r.delta.log}`);
z = letzteLogZeile();
check("3 subject_id ist die GELESENE Person", z.subject === ZIEL_PERSON, `subject ${z.subject}`);

}

// 4 schreibend, erlaubt — app.load_deviations ist leer, also NOT_FOUND (Regel 3, keine Rechtefrage)
r = await tuer("rpc_review_deviation", { p_deviation_id: "00000000-0000-0000-0000-0000000000ff", p_decision: "release" });
check("4 rpc_review_deviation antwortet, keine Ablehnung", r.status !== 403, `HTTP ${r.status}`);
check("4 Antwort ist NOT_FOUND (P0002), app.load_deviations ist leer", r.parsed?.code === "P0002", `${r.parsed?.code} ${r.parsed?.message ?? ""}`);
check("4 nichts gewachsen", r.delta.log === 0 && r.delta.deny === 0, `log ${r.delta.log}, deny ${r.delta.deny}`);

if (MODUS === "--check") {
// 5 schreibend, erlaubt
r = await tuer("rpc_propose_clearance", { p_person_id: ZIEL_PERSON, p_status: "limited", p_rationale: "AP-47a Cloud-Beleg, Testzeile" });
check("5 rpc_propose_clearance antwortet mit 200", r.status === 200, `HTTP ${r.status}`);
check("5 genau ein Vorschlag mehr", r.delta.vorschlaege === 1, `${r.delta.vorschlaege}`);
check("5 KEINE Freigabe geschrieben", r.delta.freigaben === 0, `${r.delta.freigaben}`);
check("5 eine access_log Zeile (Punkt 56)", r.delta.log === 1, `${r.delta.log}`);
z = letzteLogZeile();
check("5 Zeile ist action=write auf die Zielperson", z.action === "write" && z.subject === ZIEL_PERSON, `${z.action} ${z.subject}`);

// 6 schreibend, VERBOTEN fuer physio
r = await tuer("rpc_set_clearance", { p_person_id: ZIEL_PERSON, p_status: "full", p_load_note: "darf nicht passieren" });
check("6 rpc_set_clearance antwortet mit HTTP 403", r.status === 403, `HTTP ${r.status}`);
check("6 code ist 42501", r.parsed?.code === "42501", String(r.parsed?.code));
check("6 details und hint sind null", r.parsed?.details === null && r.parsed?.hint === null);
check("6 message beginnt mit FORBIDDEN", String(r.parsed?.message ?? "").startsWith("FORBIDDEN"), String(r.parsed?.message));
check("6 genau eine deny Zeile", r.delta.deny === 1, `${r.delta.deny}`);
check("6 KEINE Freigabe geschrieben", r.delta.freigaben === 0, `${r.delta.freigaben}`);

}

// Positivkontrolle: eine alte Tuer, unveraendert erreichbar
const pk = MODUS === "--check" ? await fetch(`${BASE}/rest/v1/rpc/rpc_my_body_map_figure`, { method: "POST", headers: auth, body: "{}" }) : null;
const pkText = pk ? await pk.text() : "";
if (pk) {
console.log(`\n--- Positivkontrolle rpc_my_body_map_figure — HTTP ${pk.status}: ${pkText.slice(0, 120)}`);
check("Positivkontrolle: alte Tuer antwortet unveraendert", pk.status === 200, `HTTP ${pk.status}`);
}

await fetch(`${BASE}/auth/v1/logout?scope=local`, { method: "POST", headers: auth });
console.log("\nSitzung abgemeldet (scope=local)");

process.exit(failed ? 1 : 0);
