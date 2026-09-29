import { describe, expect, it } from "vitest";
import { g01Violations } from "@/lib/ai/guardrails";
import { assertKeysSubset, assertValueProvenance } from "@/lib/ai/gateway/guard";
import {
  BAND_CRITERIA,
  CHECKIN_CRITERIA,
  CLEARANCE_CRITERIA,
  INTENT_CRITERIA,
  TRAINER_QUERY_OUTPUT_ALLOWLIST,
  UNSUPPORTED_REASON_CRITERIA,
  playerRefCriteria,
  positionCriteria,
} from "./schema";
import { buildPlayerRefs, resolvePlayerRefs } from "./resolve";
import { evaluateTrainerQuery, parseTrainerQueryAnswers, type ParsedTrainerQueryAnswers } from "./evaluate";
import { renderTrainerQueryAnswer } from "./render";
import type { CoachKaderPayload } from "@/lib/trainer/types";

function payload(): CoachKaderPayload {
  return {
    kaderName: "Test",
    syncState: "live",
    asOf: "2026-09-29",
    members: [
      {
        player: { id: "11111111-1111-1111-1111-111111111111", jersey: 11, name: "Max Mustermann", position: "sturm" },
        readiness: { band: "low" },
        baseline: { series: [], rollingAvg: 0 },
        medicalStatus: "green",
        medicalClearance: "frei",
        attendance: "anwesend",
        todayEvent: "none",
        hasCheckIn: true,
      },
      {
        player: { id: "22222222-2222-2222-2222-222222222222", jersey: 7, name: "Erika Musterfrau", position: "abwehr" },
        readiness: { band: "high" },
        baseline: { series: [], rollingAvg: 0 },
        medicalStatus: "green",
        medicalClearance: "eingeschraenkt",
        attendance: "anwesend",
        todayEvent: "none",
        hasCheckIn: false,
      },
    ],
  };
}

describe("G-01: Trainer-Query Prompt-Kriterien", () => {
  it("kein Kriterientext verstoesst gegen G-01", () => {
    const groups = [INTENT_CRITERIA, BAND_CRITERIA, CLEARANCE_CRITERIA, CHECKIN_CRITERIA, UNSUPPORTED_REASON_CRITERIA];
    for (const group of groups) {
      for (const { what, not_for } of Object.values(group)) {
        expect(g01Violations(what), what).toEqual([]);
        expect(g01Violations(not_for), not_for).toEqual([]);
      }
    }
  });

  it("dynamische player_ref/position Kriterien verstossen nicht gegen G-01", () => {
    const refs = playerRefCriteria(["P01", "P02"]);
    const positions = positionCriteria(["sturm", "abwehr"]);
    for (const group of [refs, positions]) {
      for (const { what, not_for } of Object.values(group)) {
        expect(g01Violations(what)).toEqual([]);
        expect(g01Violations(not_for)).toEqual([]);
      }
    }
  });
});

describe("resolve.ts: Pseudonymisierung", () => {
  it("ersetzt einen Namen durch den zugehoerigen P-Ref", () => {
    const result = resolvePlayerRefs("Wie geht es Max Mustermann heute?", payload());
    expect(result.pseudonymizedQuestion).not.toMatch(/Max Mustermann/);
    expect(result.mentionedRefs).toHaveLength(1);
    expect(result.mentionedRefs[0].name).toBe("Max Mustermann");
  });

  it("ersetzt eine Rueckennummer durch den zugehoerigen P-Ref", () => {
    const result = resolvePlayerRefs("Ist Nummer 7 heute eingeschraenkt?", payload());
    expect(result.mentionedRefs).toHaveLength(1);
    expect(result.mentionedRefs[0].jersey).toBe(7);
  });

  it("eine Frage ohne Namen/Nummer nennt keinen mentionedRef", () => {
    const result = resolvePlayerRefs("Wie viele haben heute kein Checkin?", payload());
    expect(result.mentionedRefs).toHaveLength(0);
    expect(result.refs).toHaveLength(2);
  });

  it("P-Refs sind stabil geformt (P + Ziffern, Mindestbreite 2)", () => {
    const refs = buildPlayerRefs(payload());
    for (const r of refs) expect(r.ref).toMatch(/^P\d{2,}$/);
  });
});

describe("evaluate.ts: deterministische Auswertung", () => {
  const refs = buildPlayerRefs(payload());

  function parsed(overrides: Partial<ParsedTrainerQueryAnswers>): ParsedTrainerQueryAnswers {
    return {
      intent: "list",
      band: "any",
      clearance: "any",
      checkin: "any",
      position: "any",
      playerRef: "keine",
      unsupportedReason: "none",
      ...overrides,
    };
  }

  it("filtert nach band", () => {
    const result = evaluateTrainerQuery(parsed({ band: "low" }), refs);
    expect(result.kind).toBe("list");
    if (result.kind === "list") {
      expect(result.players).toHaveLength(1);
      expect(result.players[0].name).toBe("Max Mustermann");
    }
  });

  it("filtert nach hasCheckIn", () => {
    const result = evaluateTrainerQuery(parsed({ checkin: "no", intent: "count" }), refs);
    expect(result.kind).toBe("count");
    if (result.kind === "count") expect(result.count).toBe(1);
  });

  it("intent unsupported liefert keine Spielerdaten", () => {
    const result = evaluateTrainerQuery(parsed({ intent: "unsupported", unsupportedReason: "history" }), refs);
    expect(result).toEqual({ kind: "unsupported", reason: "history" });
  });

  it("player_ref filtert auf genau eine Person", () => {
    const result = evaluateTrainerQuery(parsed({ playerRef: refs[1].ref }), refs);
    expect(result.kind).toBe("list");
    if (result.kind === "list") {
      expect(result.players).toHaveLength(1);
      expect(result.players[0].name).toBe("Erika Musterfrau");
    }
  });

  it("guard-Bausteine: die Ausgabe besteht ausschliesslich aus Allowlist-Schluesseln mit korrekter Herkunft", () => {
    const result = evaluateTrainerQuery(parsed({}), refs);
    const doorPayload = refs.map((r) => ({
      ref: r.ref,
      name: r.name,
      jersey: r.jersey,
      position: r.position,
      band: r.band,
      medicalClearance: r.medicalClearance,
      hasCheckIn: r.hasCheckIn,
    }));
    if (result.kind === "list") {
      expect(assertKeysSubset(result.players, doorPayload, TRAINER_QUERY_OUTPUT_ALLOWLIST)).toBe(true);
      expect(assertValueProvenance(result.players, doorPayload, "ref")).toBe(true);
    }
  });
});

describe("parseTrainerQueryAnswers", () => {
  const refs = ["P01", "P02"];
  const positions = ["sturm", "abwehr"];

  it("ohne gueltiges intent ist das Ergebnis invalid", () => {
    const { resultClass } = parseTrainerQueryAnswers({ answers: {} }, refs, positions, 0.7);
    expect(resultClass).toBe("invalid");
  });

  it("mit gueltigem intent und allen Achsen ist das Ergebnis ok", () => {
    const { resultClass, parsed } = parseTrainerQueryAnswers(
      {
        answers: {
          intent: { choice: "count", confidence: 0.9 },
          band: { choice: "low", confidence: 0.9 },
          clearance: { choice: "any", confidence: 0.9 },
          checkin: { choice: "any", confidence: 0.9 },
          position: { choice: "any", confidence: 0.9 },
          player_ref: { choice: "keine", confidence: 0.9 },
          unsupported_reason: { choice: "none", confidence: 0.9 },
        },
      },
      refs,
      positions,
      0.7,
    );
    expect(resultClass).toBe("ok");
    expect(parsed.intent).toBe("count");
    expect(parsed.band).toBe("low");
  });

  it("eine fehlende Nebenachse degradiert auf 'partial', nicht auf 'invalid'", () => {
    const { resultClass, parsed } = parseTrainerQueryAnswers(
      { answers: { intent: { choice: "list", confidence: 0.9 } } },
      refs,
      positions,
      0.7,
    );
    expect(resultClass).toBe("partial");
    expect(parsed.band).toBe("any");
  });
});

describe("render.ts: feste Vorlagen", () => {
  it("traegt immer das Label KI-Antwort", () => {
    const view = renderTrainerQueryAnswer({ kind: "count", count: 3, matched: [] });
    expect(view.label).toBe("KI-Antwort");
  });

  it("unsupported liefert keine Zeilen mit Spielerdaten", () => {
    const view = renderTrainerQueryAnswer({ kind: "unsupported", reason: "medical_detail" });
    expect(view.lines.join(" ")).not.toMatch(/Mustermann/);
  });
});
