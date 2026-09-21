#!/usr/bin/env node
// Team Performance OS — AP-39b Schritt 0: Gegenprobe zu Teil E des Legacy Audits
//
// Frage: gilt das Medizin Gate aus ADR-009 im Legacy Pfad `public.*`, wenn ein echter
// Trainer mit echtem JWT ueber PostgREST liest? Teil E des Audits hat das Policy
// Praedikat mit gesetztem Claim gemessen und behauptet: nein, ein Trainer sieht alle
// 280 Check-In Zeilen samt `soreness`. Dieses Skript prueft dieselbe Behauptung ueber
// die echte Kette Login, JWT, PostgREST, RLS.
//
// Aufruf:
//   node scripts/ap39-gate-probe.mjs --check
//
// Was das Skript tut (alles lesend):
//   1. Service Key aus `supabase projects api-keys` in eine Variable (nie in eine Datei).
//   2. Admin `generate_link` (magiclink) fuer den Trainer. Verschickt KEINE Mail.
//   3. `POST /auth/v1/verify` mit dem `hashed_token` liefert eine echte Sitzung.
//   4. Lesende Anfragen an PostgREST mit genau diesem Access Token.
//
// Was es NICHT tut: schreiben, Werte aus Gesundheitsdaten ausgeben, Tokens ausgeben.
// Die Ausgabe ist PASS oder FAIL je Pruefpunkt plus Zeilenzahlen.
//
// Nebenwirkung, bekannt und von Chris am 2026-09-21 freigegeben (Entscheidung 6):
// `auth.sessions` waechst um eins. Das Skript meldet genau diese Sitzung am Ende
// wieder ab (scope=local), damit der Refresh Token endet.
//
// Erlaubnisregel fuer Claude Code: "Bash(node scripts/ap39-gate-probe.mjs *)".

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const COACH_EMAIL = "coach@c-klan.de";

const mode = process.argv[2];
if (mode !== "--check") {
  console.error("Aufruf: node scripts/ap39-gate-probe.mjs --check");
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
if (!BASE) throw new Error("NEXT_PUBLIC_SUPABASE_URL fehlt in .env.local");
if (!ANON) throw new Error("NEXT_PUBLIC_SUPABASE_ANON_KEY fehlt in .env.local");

const keys = JSON.parse(
  execFileSync("supabase", ["projects", "api-keys", "--project-ref", REF, "-o", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }),
);
const serviceKey = keys.find((k) => k.name === "service_role" || k.id === "service_role")?.api_key;
if (!serviceKey) throw new Error("service key nicht gefunden");

let failed = false;
function check(name, ok, detail = "") {
  if (!ok) failed = true;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
}

// ---------------------------------------------------------------------------
// 1. Echte Sitzung fuer den Trainer, ohne Mailversand
// ---------------------------------------------------------------------------

const linkRes = await fetch(`${BASE}/auth/v1/admin/generate_link`, {
  method: "POST",
  headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
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
check("JWT traegt team_id", Boolean(claims.team_id));
check("JWT traegt KEIN tenant_id (ADR-015)", claims.tenant_id === undefined);

const auth = { apikey: ANON, Authorization: `Bearer ${session.access_token}` };

// ---------------------------------------------------------------------------
// 2. Die Gegenprobe: was sieht dieser Trainer in public.daily_checkins
// ---------------------------------------------------------------------------

async function countRows(path) {
  const r = await fetch(`${BASE}/rest/v1/${path}`, {
    headers: { ...auth, Prefer: "count=exact", Range: "0-0" },
  });
  const range = r.headers.get("content-range") ?? "";
  const total = Number(range.split("/")[1]);
  // PostgREST antwortet auf eine begrenzte Auswahl mit 206 Partial Content, auf eine
  // leere Menge mit 200. Beides ist ein erfolgreicher Lesezugriff.
  return { ok: r.status === 200 || r.status === 206, status: r.status, total: Number.isFinite(total) ? total : null };
}

const all = await countRows("daily_checkins?select=id");
check(
  "Teil E: Trainer liest Zeilen in public.daily_checkins",
  all.ok && (all.total ?? 0) > 0,
  `HTTP ${all.status}, ${all.total ?? "-"} Zeilen`,
);

const withSoreness = await countRows("daily_checkins?select=id&soreness=not.is.null");
check(
  "Teil E: davon Zeilen mit soreness (Art. 9, ADR-009 verbietet das fuer Trainer)",
  withSoreness.ok && (withSoreness.total ?? 0) > 0,
  `${withSoreness.total ?? "-"} Zeilen`,
);

// Spaltenzugriff belegen, ohne einen Wert auszugeben: eine Anfrage, die nach
// soreness filtert, setzt Lesbarkeit der Spalte voraus.
const sorenessSelect = await fetch(`${BASE}/rest/v1/daily_checkins?select=soreness&limit=1`, { headers: auth });
check("Teil E: Spalte soreness ist fuer den Trainer waehlbar", sorenessSelect.status === 200, `HTTP ${sorenessSelect.status}`);

const freeText = await countRows("daily_checkins?select=id&free_text=not.is.null");
check(
  "Teil E: free_text ist heute leer (Spalte existiert, Seed fuellt sie nicht)",
  freeText.ok && freeText.total === 0,
  `HTTP ${freeText.status}, ${freeText.total ?? "-"} Zeilen`,
);

// ---------------------------------------------------------------------------
// 3. Kontrolle: die Zielarchitektur app.* haelt das Gate
// ---------------------------------------------------------------------------

const appDirect = await fetch(`${BASE}/rest/v1/daily_checkins?select=body_map&limit=1`, {
  headers: { ...auth, "Accept-Profile": "app" },
});
check(
  "Kontrolle: Schema app ist ueber PostgREST nicht erreichbar",
  appDirect.status >= 400,
  `HTTP ${appDirect.status}`,
);

const morningOps = await fetch(`${BASE}/rest/v1/rpc/rpc_trainer_morning_ops`, {
  method: "POST",
  headers: { ...auth, "Content-Type": "application/json" },
  body: JSON.stringify({}),
});
const morningBody = morningOps.ok ? await morningOps.json() : null;
const morningKeys = Array.isArray(morningBody) && morningBody.length > 0 ? Object.keys(morningBody[0]) : [];
if (morningKeys.length === 0) {
  // Keine Zeile heute (der Seed ist abgelaufen). Ein leeres Ergebnis belegt nichts
  // ueber die Felder, deshalb hier kein PASS, sondern ein Hinweis.
  console.log(`HINWEIS  Tuer rpc_trainer_morning_ops antwortet leer, Feldpruefung ohne Aussage  (HTTP ${morningOps.status})`);
} else {
  check(
    "Kontrolle: die Tuer fuer Trainer gibt weder body_map noch pain_max",
    morningOps.status === 200 && !morningKeys.includes("body_map") && !morningKeys.includes("pain_max"),
    `Felder: ${morningKeys.join(",")}`,
  );
}

// ---------------------------------------------------------------------------
// 4. Sitzung beenden
// ---------------------------------------------------------------------------

// scope=local beendet genau diese eine Sitzung. Der erste Lauf am 2026-09-21
// benutzte scope=global und hat damit auch die aelteren Sitzungen desselben
// Trainers beendet (auth.sessions fiel von 5 auf 1). Kein Datenverlust, aber
// mehr als noetig.
const signOut = await fetch(`${BASE}/auth/v1/logout?scope=local`, { method: "POST", headers: auth });
check("Sitzung abgemeldet", signOut.status === 204 || signOut.status === 200, `HTTP ${signOut.status}`);

console.log("");
if (failed) {
  console.log("ERGEBNIS: Teil E NICHT wie beschrieben bestaetigt. Audit korrigieren, bevor gebaut wird.");
  process.exit(1);
}
console.log("ERGEBNIS: Teil E bestaetigt. Im Legacy Pfad public.* greift das Medizin Gate aus ADR-009 nicht.");
