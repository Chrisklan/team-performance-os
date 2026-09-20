#!/usr/bin/env node
// Team Performance OS — Login ohne Mail (AP-38, Werkzeug fuer Tests ohne Geraet)
//
// Modi:
//   node scripts/sim-login.mjs --check   Allowlist Readback (funktional) und Format der Rueckkehradresse.
//                                        Verschickt KEINE Mail, schreibt nichts in Tabellen. Erzeugt beim
//                                        Verify serverseitig eine Session (auth.sessions +1) wie jeder Login.
//   node scripts/sim-login.mjs --sim-prepare   Wie --check, danach im gebooteten iOS Simulator: App beenden und
//                                        Wartestatus (tpos.auth.pendingLoginRequestedAt = jetzt) in AsyncStorage setzen.
//                                        Danach die App neu starten und mit Metro verbinden (Wartestatus gilt 15 Minuten).
//   node scripts/sim-login.mjs --sim-open      Wie --check (frischer Einmal Link), danach die Rueckkehradresse per
//                                        `xcrun simctl openurl` im Simulator oeffnen (iOS fragt "Oeffnen?", antippen).
//   node scripts/sim-login.mjs --sim-open-used Wie --sim-open, aber der Link wurde vorher einmal aufgerufen (wie von einem
//                                        Mail Scanner). Zeigt, was die App bei einem verbrauchten Link tut (Punkt 9).
//
// Der Service Key bleibt im Speicher, Tokens und die Rueckkehradresse werden nie ausgegeben
// (nur Schluesselnamen und PASS/FAIL). Die Adresse geht als Argument an simctl (nur lokal, kurz sichtbar in ps).
// Voraussetzung: supabase CLI eingeloggt und gelinkt, .env.local mit NEXT_PUBLIC_SUPABASE_URL.
// Erlaubnisregel fuer Claude Code: "Bash(node scripts/sim-login.mjs *)" in .claude/settings.local.json.
//
// STATUS: Entwurf. --check ist die Wiederholung des Readbacks vom 2026-09-19 (lief dort fehlerfrei),
// --sim-prepare und --sim-open: gegen den Simulator iPhone 17 (iOS 27.0) am 2026-09-20 getestet.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const EMAIL = "spieler@c-klan.de";
const APP_ID = "de.klanlabs.tpos.player";
const CALLBACK = "tpos://auth/callback";
const PENDING_KEY = "tpos.auth.pendingLoginRequestedAt";
const mode = process.argv[2];
if (!["--check", "--sim-prepare", "--sim-open", "--sim-open-used"].includes(mode)) {
  console.error("Aufruf: node scripts/sim-login.mjs --check | --sim-prepare | --sim-open | --sim-open-used");
  process.exit(2);
}

const env = Object.fromEntries(
  readFileSync(join(ROOT, ".env.local"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const URL_ = env.NEXT_PUBLIC_SUPABASE_URL;
if (!URL_) throw new Error("NEXT_PUBLIC_SUPABASE_URL fehlt in .env.local");

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

async function generateLink(redirectTo) {
  const r = await fetch(`${URL_}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email: EMAIL, redirect_to: redirectTo }),
  });
  const j = await r.json();
  return { status: r.status, link: j.action_link ?? null };
}

// 1. Allowlist Readback, mit Fremdadresse als Gegenprobe
const foreign = await generateLink("https://fremd.example.org/cb");
const foreignRedirect = foreign.link ? new URL(foreign.link).searchParams.get("redirect_to") : null;
check("Gegenprobe: Fremdadresse wird abgelehnt", foreignRedirect !== "https://fremd.example.org/cb", `redirect_to ${foreignRedirect}`);

const own = await generateLink(CALLBACK);
const ownRedirect = own.link ? new URL(own.link).searchParams.get("redirect_to") : null;
check("Allowlist: tpos://auth/callback erlaubt", ownRedirect === CALLBACK, `redirect_to ${ownRedirect}`);
if (!own.link || ownRedirect !== CALLBACK) process.exit(1);

// 2. Verify ohne Redirect zu folgen: die Location ist die Adresse, die die App bekommen wuerde
const v = await fetch(own.link, { redirect: "manual" });
const location = v.headers.get("location") ?? "";
const hashAt = location.indexOf("#");
const names = (part) => part.split("&").map((p) => p.split("=", 1)[0]).filter(Boolean);
const fragmentKeys = hashAt === -1 ? [] : names(location.slice(hashAt + 1));
check("Verify antwortet mit Redirect", v.status === 302 || v.status === 303, `HTTP ${v.status}`);
check("Location beginnt mit tpos://auth/callback#", location.startsWith(`${CALLBACK}#`));
check(
  "Fragment enthaelt access_token und refresh_token",
  fragmentKeys.includes("access_token") && fragmentKeys.includes("refresh_token"),
  `Schluessel: ${fragmentKeys.join(",") || "-"}`,
);
if (failed || mode === "--check") process.exit(failed ? 1 : 0);


// 3. Simulator
function simctl(...args) {
  return execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" }).trim();
}

if (mode === "--sim-open-used") {
  // Zweiter Aufruf desselben Links: GoTrue antwortet mit einem Fehler Fragment statt mit Tokens
  const again = await fetch(own.link, { redirect: "manual" });
  const usedLocation = again.headers.get("location") ?? "";
  const usedKeys = usedLocation.includes("#") ? names(usedLocation.slice(usedLocation.indexOf("#") + 1)) : [];
  const codeAt = usedLocation.match(/error_code=([a-z_]+)/);
  check("Zweiter Aufruf liefert Fehler Fragment", usedKeys.includes("error"), `Schluessel: ${usedKeys.join(",") || "-"}, error_code ${codeAt?.[1] ?? "-"}`);
  simctl("openurl", "booted", usedLocation);
  console.log("Verbrauchten Link geoeffnet. Ergebnis per Screenshot pruefen.");
  process.exit(0);
}

if (mode === "--sim-open") {
  simctl("openurl", "booted", location);
  console.log("Adresse geoeffnet (iOS Dialog antippen). Ergebnis per Screenshot pruefen.");
  process.exit(0);
}

// --sim-prepare: Wartestatus setzen, solange die App nicht laeuft (sie haelt AsyncStorage im Speicher)
const container = simctl("get_app_container", "booted", APP_ID, "data");
const storageDir = execFileSync("find", [container, "-type", "d", "-name", "RCTAsyncLocalStorage_V1"], {
  encoding: "utf8",
})
  .split("\n")
  .find(Boolean);
check("AsyncStorage Ordner im Simulator gefunden", Boolean(storageDir));
if (!storageDir) process.exit(1);
const manifest = join(storageDir, "manifest.json");

try { simctl("terminate", "booted", APP_ID); } catch { /* lief nicht */ }
const data = existsSync(manifest) ? JSON.parse(readFileSync(manifest, "utf8")) : {};
data[PENDING_KEY] = String(Date.now());
writeFileSync(manifest, JSON.stringify(data));
console.log("Wartestatus gesetzt, App beendet. App neu starten, mit Metro verbinden, dann --sim-open.");
