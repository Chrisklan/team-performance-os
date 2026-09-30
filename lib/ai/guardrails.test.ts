// ADR-019 T3 (kein service_role im Modellpfad, kein Modellzugang aus dem Client)
// und T5 (G-01 auf Prompts) fuer AP-69.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { G01_MODEL_TEXT_BLACKLIST, g01Violations } from "./guardrails";
import { JEV_CRITERIA, JEV_FOCUS, jevPromptTexts } from "@/lib/planung/jevSquadCheck";
import { allowedGatewayRpcNames } from "./gateway/purposes";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

function filesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...filesUnder(full));
    else if (/\.(ts|tsx)$/.test(name)) out.push(full);
  }
  return out;
}

describe("T3: kein service_role im Modellpfad", () => {
  // Security-Review AP-70b, I-3: lib/trainerQuery ergaenzt -- der Scan deckte
  // vorher nur lib/ai/lib/planung ab, ein Umbau von lib/trainerQuery (z.B. ein
  // Admin-Client) waere von keinem Test bemerkt worden.
  const files = [
    ...filesUnder(join(ROOT, "lib/ai")),
    ...filesUnder(join(ROOT, "lib/planung")),
    ...filesUnder(join(ROOT, "lib/trainerQuery")),
  ].filter((f) => !f.endsWith(".test.ts"));

  it("findet die Dateien des Modellpfads", () => {
    const rel = files.map((f) => relative(ROOT, f));
    expect(rel).toContain("lib/ai/jev.ts");
    // AP-70a: der Gateway-Kern liegt unter lib/ai/gateway und ist Teil des
    // Modellpfads -- filesUnder(lib/ai) findet ihn bereits rekursiv mit,
    // diese Zeile macht das explizit statt implizit.
    expect(rel).toContain("lib/ai/gateway/run.ts");
    expect(rel).toContain("lib/ai/gateway/db.ts");
    expect(rel).toContain("lib/ai/gateway/purposes.ts");
    expect(rel).toContain("lib/planung/squadCheckActions.ts");
    // AP-70b (Security-Review I-3): der Trainer-Query-Modellpfad.
    expect(rel).toContain("lib/trainerQuery/queryActions.ts");
    expect(rel).toContain("lib/trainerQuery/spec.ts");
  });

  it("kein SERVICE_ROLE, kein service_role, kein NEXT_PUBLIC fuer Modell-Keys", () => {
    for (const f of files) {
      const text = readFileSync(f, "utf8");
      expect(text, relative(ROOT, f)).not.toMatch(/SERVICE_ROLE|service_role|serviceRole/);
      // L3 (Fixrunde): NEXT_PUBLIC_MODEL_GATEWAY ergaenzt -- die T3-Regex
      // pruefte bisher nur die alten OPENROUTER/JEV-Praefixe, nicht den
      // neuen Gateway-Namen (lib/ai/gateway/config.ts).
      expect(text, relative(ROOT, f)).not.toMatch(/NEXT_PUBLIC_(OPENROUTER|JEV|MODEL_GATEWAY)/);
    }
  });

  it("kein SQL-Werkzeug und kein direkter Tabellenzugriff im Modellpfad", () => {
    for (const f of files) {
      const text = readFileSync(f, "utf8");
      expect(text, relative(ROOT, f)).not.toMatch(/\.from\(\s*["'`]/);
      expect(text, relative(ROOT, f)).not.toMatch(/\bpg\b|postgres\(|createPool/);
    }
  });

  it("RPC-Namen im Gateway-Kern (lib/ai/gateway) sind Teilmenge der Registry aus purposes.ts", () => {
    const allowed = allowedGatewayRpcNames();
    expect(allowed.size).toBeGreaterThan(0);
    const gatewayFiles = filesUnder(join(ROOT, "lib/ai/gateway")).filter((f) => !f.endsWith(".test.ts"));
    const rpcCallPattern = /\.rpc\(\s*["'`]([^"'`]+)["'`]/g;
    let sawAny = false;
    for (const f of gatewayFiles) {
      const text = readFileSync(f, "utf8");
      for (const match of text.matchAll(rpcCallPattern)) {
        sawAny = true;
        expect(allowed.has(match[1]), `${relative(ROOT, f)}: RPC-Name "${match[1]}" nicht in der Registry`).toBe(true);
      }
    }
    // Heutiger Stand: der Kern ruft die Namen ausschliesslich dynamisch
    // (spec.openDoor / GATEWAY_FINISH_DOOR), kein Literal matcht -- dieser
    // Test greift trotzdem sofort, sobald jemand einen Literal-Namen einfuehrt.
    expect(sawAny).toBe(false);
  });

  // N-3-Rest (Security-Re-Review, I-3-Rest aus AP-70b): der obige Scan deckte
  // nur lib/ai/gateway ab. lib/trainerQuery ist Teil des T3-Scans weiter oben
  // (.from(/service_role), aber nicht dieses spezifischere .rpc()-Literalscans
  // gegen die Registry -- ein kuenftiger direkter supabase.rpc(...)-Aufruf in
  // lib/trainerQuery (statt ueber gatewayDb(...).readDoor) waere sonst von
  // keinem Test bemerkt worden.
  it("RPC-Namen in lib/trainerQuery sind Teilmenge der Registry aus purposes.ts", () => {
    const allowed = allowedGatewayRpcNames();
    const trainerQueryFiles = filesUnder(join(ROOT, "lib/trainerQuery")).filter((f) => !f.endsWith(".test.ts"));
    const rpcCallPattern = /\.rpc\(\s*["'`]([^"'`]+)["'`]/g;
    let sawAny = false;
    for (const f of trainerQueryFiles) {
      const text = readFileSync(f, "utf8");
      for (const match of text.matchAll(rpcCallPattern)) {
        sawAny = true;
        expect(allowed.has(match[1]), `${relative(ROOT, f)}: RPC-Name "${match[1]}" nicht in der Registry`).toBe(true);
      }
    }
    // Heutiger Stand: lib/trainerQuery greift ausschliesslich ueber
    // gatewayDb(...).readDoor zu, kein Literal-Name matcht.
    expect(sawAny).toBe(false);
  });

  // N-3-Rest: createSupabaseServerClient ist in lib/trainerQuery komplett
  // untersagt, nicht nur .rpc()-Literale -- ein direkter Admin-/Server-Client
  // wuerde den Gateway-Kern (samt Pseudonymisierung/Registry-Scan) umgehen.
  it("createSupabaseServerClient wird in lib/trainerQuery nicht importiert", () => {
    const trainerQueryFiles = filesUnder(join(ROOT, "lib/trainerQuery")).filter((f) => !f.endsWith(".test.ts"));
    for (const f of trainerQueryFiles) {
      const text = readFileSync(f, "utf8");
      expect(text, relative(ROOT, f)).not.toMatch(/createSupabaseServerClient/);
    }
  });

  it("die Registry selbst nennt genau die heute bekannten Tueren (AP-69 und AP-70b)", () => {
    const allowed = allowedGatewayRpcNames();
    expect(allowed.has("rpc_squad_check_jev_context")).toBe(true);
    expect(allowed.has("rpc_finish_model_call")).toBe(true);
    // AP-70b (Security-Review I-3): Tuer-Oeffner und Lese-Tuer der
    // Trainer-Query-Funktion sind Teil der Registry.
    expect(allowed.has("rpc_trainer_query_open")).toBe(true);
    expect(allowed.has("rpc_trainer_morning_ops")).toBe(true);
  });

  it("lib/ai wird aus keiner Client-Komponente importiert", () => {
    const clientFiles = [
      ...filesUnder(join(ROOT, "components")),
      ...filesUnder(join(ROOT, "app")),
      ...filesUnder(join(ROOT, "lib")),
    ].filter((f) => /^\s*["']use client["']/.test(readFileSync(f, "utf8")));
    for (const f of clientFiles) {
      expect(readFileSync(f, "utf8"), relative(ROOT, f)).not.toMatch(/from\s+["']@\/lib\/ai\//);
    }
  });

  it("jev.ts wird nur aus Server-Modulen importiert", () => {
    const importers = [...filesUnder(join(ROOT, "app")), ...filesUnder(join(ROOT, "lib")), ...filesUnder(join(ROOT, "components"))]
      .filter((f) => !f.endsWith(".test.ts"))
      .filter((f) => /from\s+["']@\/lib\/ai\/jev["']/.test(readFileSync(f, "utf8")));
    for (const f of importers) {
      const text = readFileSync(f, "utf8");
      expect(/^\s*["']use client["']/.test(text), relative(ROOT, f)).toBe(false);
    }
    expect(importers.length).toBeGreaterThan(0);
  });

  it("Request- und Response-Bodies werden nicht geloggt", () => {
    for (const f of [join(ROOT, "lib/ai/jev.ts"), join(ROOT, "lib/planung/squadCheckActions.ts")]) {
      const text = readFileSync(f, "utf8");
      const logs = text.match(/console\.\w+\([^)]*\)/g) ?? [];
      for (const call of logs) {
        expect(call).not.toMatch(/body|request|response|state|questions|answers|ctx|candidates/i);
      }
    }
  });
});

describe("T5: G-01 auf den Prompt-Konstanten", () => {
  it("die Sperrliste ist nicht leer und enthaelt die Kernbegriffe", () => {
    for (const word of ["diagnos", "verletz", "injur", "risiko", "risk", "pain", "probab"]) {
      expect(G01_MODEL_TEXT_BLACKLIST).toContain(word);
    }
  });

  it("g01Violations erkennt verbotene Woerter ohne Gross/Kleinschreibung", () => {
    expect(g01Violations("Injury risk is HIGH")).toEqual(expect.arrayContaining(["injur", "risk"]));
    expect(g01Violations("full group")).toEqual([]);
  });

  it("kein Prompt-Text verstoesst gegen G-01", () => {
    for (const text of jevPromptTexts("A01")) {
      expect(g01Violations(text), text).toEqual([]);
    }
    expect(g01Violations(JEV_FOCUS)).toEqual([]);
    expect(g01Violations(JSON.stringify(JEV_CRITERIA))).toEqual([]);
  });

  it("kein Prompt-Text nennt eine Zahl als Stufe", () => {
    for (const text of [JEV_FOCUS, ...Object.values(JEV_CRITERIA).flatMap((c) => [c.what, c.not_for])]) {
      expect(text).not.toMatch(/\b\d+\s*(bis|to|-)\s*\d+\b/);
    }
  });
});
