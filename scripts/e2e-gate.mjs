#!/usr/bin/env node
// Team Performance OS — E2E Pilot-Gate ohne Geraet (AP-35)
//
// Beweist die Kette gegen die Cloud-DB tpos-pilot:
//   Spieler-JWT -> public.rpc_submit_checkin -> app.daily_checkins + app.readiness_scores
//   Trainer-JWT -> public.rpc_trainer_morning_ops -> hasCheckIn true, Score stimmt
// plus Negativfaelle (Spieler auf Trainer-Tuer, Trainer auf Check-In-Tuer, anon)
// und das Medizin-Gate (kein diagnosis/symptoms/treatment/reha_phase, kein body_map im Coach-Payload).
//
// Schreibt in die Cloud: genau EINEN Check-In der Spieler-Person fuer heute. Die Zeilen in
// app.daily_checkins und app.readiness_scores werden vorher gesichert und am Ende
// wiederhergestellt (oder geloescht, wenn es vorher keine gab). Zeilenzahlen vorher/nachher.
//
// Sessions ohne Mail: Admin generate_link + verifyOtp. Keys werden nie ausgegeben.
// Voraussetzung: supabase CLI eingeloggt und gelinkt, .env.local mit URL und Anon-Key.
// Aufruf: node scripts/e2e-gate.mjs      (Exit 0 = alle Pruefungen gruen)

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REF = "sxpfetwrqqwqijapgkcd";
const PLAYER_EMAIL = "spieler@c-klan.de";
const COACH_EMAIL = "coach@c-klan.de";
const FORBIDDEN_KEYS = ["diagnosis", "symptoms", "treatment", "reha_phase", "body_map"];

const env = Object.fromEntries(
  readFileSync(join(ROOT, ".env.local"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const URL_ = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!URL_ || !ANON) throw new Error("NEXT_PUBLIC_SUPABASE_URL/ANON_KEY fehlen in .env.local");

// ---------- Hilfen -------------------------------------------------------------------------
const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: Boolean(ok), detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
}

function sql(query) {
  const out = execFileSync("supabase", ["db", "query", "--linked", query], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return JSON.parse(out.slice(out.indexOf("{"))).rows;
}

let serviceKey; // nur im Speicher
function getServiceKey() {
  if (!serviceKey) {
    const keys = JSON.parse(
      execFileSync("supabase", ["projects", "api-keys", "--project-ref", REF, "-o", "json"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }),
    );
    serviceKey = keys.find((k) => k.name === "service_role" || k.id === "service_role").api_key;
  }
  return serviceKey;
}

async function sessionFor(email) {
  const key = getServiceKey();
  const res = await fetch(`${URL_}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email }),
  });
  const { hashed_token: tokenHash } = await res.json();
  const client = createClient(URL_, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.auth.verifyOtp({ type: "magiclink", token_hash: tokenHash });
  if (error) throw new Error(`Login ${email} fehlgeschlagen: ${error.message}`);
  const claims = JSON.parse(Buffer.from(data.session.access_token.split(".")[1], "base64url").toString());
  return { client, claims };
}

const counts = () =>
  sql(`select (select count(*) from app.persons) persons, (select count(*) from app.role_assignments) roles,
       (select count(*) from app.daily_checkins) checkins, (select count(*) from app.readiness_scores) scores,
       (select count(*) from auth.users) users, (select count(*) from app.audit_log) audit,
       (select count(*) from public.daily_checkins) pub`)[0];

function restoreSql(table, row) {
  const cols = Object.keys(row).filter((c) => c !== "id");
  return `UPDATE ${table} t SET ${cols.map((c) => `${c} = s.${c}`).join(", ")} FROM jsonb_populate_record(null::${table}, $snap$${JSON.stringify(row)}$snap$::jsonb) s WHERE t.id = s.id;`;
}

// ---------- Ablauf -------------------------------------------------------------------------
const today = new Date().toISOString().slice(0, 10);
let personId;
let snap;
let before;
let wrote = false;

try {
  console.log(`E2E Pilot-Gate, Datum ${today}, Projekt ${REF}\n`);

  personId = sql(
    `select p.id from app.persons p join auth.users u on u.id = p.auth_user_id where u.email = '${PLAYER_EMAIL}'`,
  )[0]?.id;
  check("Spieler-Person zu spieler@c-klan.de gefunden", Boolean(personId));
  if (!personId) throw new Error("Abbruch: keine Person");

  before = counts();
  console.log("Zeilen vorher:", JSON.stringify(before));
  snap = sql(
    `select (select to_jsonb(d) from app.daily_checkins d where person_id='${personId}' and date='${today}') chk,
            (select to_jsonb(r) from app.readiness_scores r where person_id='${personId}' and date='${today}') score`,
  )[0];
  console.log(`Ausgangszustand heute: Check-In ${snap.chk ? "vorhanden" : "keiner"}, Score ${snap.score ? "vorhanden" : "keiner"}\n`);

  const player = await sessionFor(PLAYER_EMAIL);
  const coach = await sessionFor(COACH_EMAIL);
  check("Spieler-JWT: app_role player, kein tenant_id", player.claims.app_role === "player" && !("tenant_id" in player.claims));
  check("Trainer-JWT: app_role coach, kein tenant_id", coach.claims.app_role === "coach" && !("tenant_id" in coach.claims));

  // Sentinel-Werte. Zweiter Satz, falls der erste zufaellig den vorhandenen Score trifft.
  const sets = [
    { q: 8, rec: 6, mood: 7, mot: 8, stress: 4 }, // Score 7.0
    { q: 6, rec: 5, mood: 6, mot: 7, stress: 5 }, // Score 5.8
  ];
  const prev = snap.score ? Number(snap.score.score_total) : null;
  const pick = sets.find((s) => (s.q + s.rec + s.mood + s.mot + (10 - s.stress)) / 5 !== prev) ?? sets[1];
  const expected = Math.round(((pick.q + pick.rec + pick.mood + pick.mot + (10 - pick.stress)) / 5) * 100) / 100;
  const expectedBand = expected >= 7 ? "high" : expected >= 5 ? "moderate" : "low";

  const args = {
    p_date: today,
    p_sleep_duration_min: 431,
    p_sleep_quality: pick.q,
    p_recovery: pick.rec,
    p_energy: 5,
    p_mental_stress: pick.stress,
    p_mental_mood: pick.mood,
    p_mental_motivation: pick.mot,
    p_training_readiness: 6,
    p_body_map: [{ region: "knee_right", pain: 3, art: "muskulaer" }],
  };

  // 1. Spieler schreibt ueber die Tuer
  wrote = true;
  const sub = await player.client.rpc("rpc_submit_checkin", args);
  check("Spieler: rpc_submit_checkin liefert eine id", !sub.error && typeof sub.data === "string", sub.error ? `${sub.error.code}` : "");

  // 2. Zeile liegt in app.*
  const row = sql(
    `select d.id, d.sleep_duration_min::float8 sleep_min, d.pain_max, d.body_map, r.score_total::float8 score, r.band::text band
     from app.daily_checkins d left join app.readiness_scores r on r.person_id = d.person_id and r.date = d.date
     where d.person_id = '${personId}' and d.date = '${today}'`,
  )[0];
  check("app.daily_checkins enthaelt den Check-In (id gleich, Schlaf 431 Min, pain_max 3)",
    row && row.id === sub.data && row.sleep_min === 431 && row.pain_max === 3);
  check(`app.readiness_scores: Score ${expected}, Band ${expectedBand}`, row && row.score === expected && row.band === expectedBand,
    row ? `ist ${row.score} ${row.band}` : "keine Zeile");

  // 3. Trainer sieht ihn
  const morning = await coach.client.rpc("rpc_trainer_morning_ops");
  check("Trainer: rpc_trainer_morning_ops ohne Fehler", !morning.error, morning.error ? morning.error.code : "");
  const payload = morning.data ?? { members: [] };
  const member = payload.members.find((m) => m.player?.id === personId);
  check("Trainer: Person im Kader-Payload, hasCheckIn true", member?.hasCheckIn === true);
  check(`Trainer: readiness.value entspricht dem Score ${expected}`, member && Number(member.readiness?.value) === expected,
    member ? `ist ${member.readiness?.value}` : "kein Member");
  check("Trainer: Kader hat Mitglieder", payload.members.length > 0, `${payload.members.length}`);

  // 4. Medizin-Gate
  const serialized = JSON.stringify(payload);
  const leaked = FORBIDDEN_KEYS.filter((k) => serialized.includes(`"${k}"`));
  check("Medizin-Gate: Coach-Payload ohne diagnosis/symptoms/treatment/reha_phase/body_map", leaked.length === 0, leaked.join(","));

  // 5. Negativfaelle
  const playerOnCoachDoor = await player.client.rpc("rpc_trainer_morning_ops");
  check("Spieler auf Trainer-Tuer: 42501 FORBIDDEN", playerOnCoachDoor.error?.code === "42501" && /FORBIDDEN/.test(playerOnCoachDoor.error.message));
  const coachSubmit = await coach.client.rpc("rpc_submit_checkin", args);
  check("Trainer auf Check-In-Tuer: 42501 FORBIDDEN", coachSubmit.error?.code === "42501" && /FORBIDDEN/.test(coachSubmit.error.message));
  const tooOld = await player.client.rpc("rpc_submit_checkin", { ...args, p_date: "2020-01-01" });
  check("Spieler mit altem Datum: 42501 FORBIDDEN date", tooOld.error?.code === "42501" && /date/.test(tooOld.error.message));
  const anon = createClient(URL_, ANON, { auth: { persistSession: false } });
  const anonA = await anon.rpc("rpc_trainer_morning_ops");
  const anonB = await anon.rpc("rpc_submit_checkin", args);
  check("anon auf beiden Tueren: 42501", anonA.error?.code === "42501" && anonB.error?.code === "42501");
  const appSchema = await player.client.schema("app").rpc("rpc_submit_checkin", args);
  check("Schema app bleibt fuer die API zu (PGRST106)", appSchema.error?.code === "PGRST106", appSchema.error?.code ?? "");
} catch (e) {
  check("Lauf ohne Ausnahme", false, String(e.message ?? e));
} finally {
  // ---------- Aufraeumen -----------------------------------------------------------------
  if (wrote && personId && snap) {
    try {
      const stmts = snap.chk
        ? [restoreSql("app.daily_checkins", snap.chk), snap.score ? restoreSql("app.readiness_scores", snap.score) : `DELETE FROM app.readiness_scores WHERE person_id='${personId}' AND date='${today}';`]
        : [`DELETE FROM app.readiness_scores WHERE person_id='${personId}' AND date='${today}';`, `DELETE FROM app.daily_checkins WHERE person_id='${personId}' AND date='${today}';`];
      sql(stmts.join("\n"));
      const after = counts();
      const now = sql(
        `select (select to_jsonb(d) from app.daily_checkins d where person_id='${personId}' and date='${today}') chk,
                (select to_jsonb(r) from app.readiness_scores r where person_id='${personId}' and date='${today}') score`,
      )[0];
      const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
      const keys = ["persons", "roles", "checkins", "scores", "users", "pub"];
      check("Aufraeumen: Ausgangszeilen wiederhergestellt", same(now.chk, snap.chk) && same(now.score, snap.score));
      check("Aufraeumen: Zeilenzahlen vorher = nachher", keys.every((k) => before[k] === after[k]),
        keys.map((k) => `${k} ${before[k]}->${after[k]}`).join(", "));
      console.log(`audit_log: ${before.audit} -> ${after.audit} (Trigger auf Insert/Update, erwartetes Wachstum)`);
    } catch (e) {
      check("Aufraeumen", false, String(e.message ?? e));
    }
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} Pruefungen gruen`);
  process.exit(failed.length === 0 ? 0 : 1);
}
