// Team Performance OS — Tests der gemeinsamen Ausgangswaechter-Bausteine
// (lib/ai/gateway/guard.ts, AP-70a). Fixrunde F2: vorher gab es KEINEN Test,
// der den Ablehnungspfad (ok:false) je tatsaechlich beobachtet hat -- diese
// Datei zeigt echte Ablehnungsfaelle, nicht nur den Erfolgspfad.

import { describe, expect, it } from "vitest";
import { assertKeysSubset, assertValueProvenance, g01ViolationsInStringValues, keyPaths } from "./guard";

describe("keyPaths", () => {
  it("sammelt jeden Schluessel in jeder Tiefe, verschachtelt und in Arrays", () => {
    const value = { a: 1, b: [{ c: 2 }, { d: { e: 3 } }] };
    expect(keyPaths(value).sort()).toEqual(["a", "b", "c", "d", "e"].sort());
  });

  it("liefert eine leere Liste fuer Primitive und null", () => {
    expect(keyPaths("text")).toEqual([]);
    expect(keyPaths(42)).toEqual([]);
    expect(keyPaths(null)).toEqual([]);
  });
});

describe("assertKeysSubset", () => {
  const doorPayload = { ref: "A01", person_id: "p-1" };
  const allowlist = ["person_id", "suggestion", "hint_key", "source"] as const;

  it("laesst eine Antwort durch, deren Schluessel nur Allowlist + Tuer-Payload sind", () => {
    const answer = { person_id: "p-1", suggestion: "reduced", hint_key: "j1", source: "jev" };
    expect(assertKeysSubset(answer, doorPayload, allowlist)).toBe(true);
  });

  it("lehnt einen vom Modell erfundenen, nirgends bekannten Schluessel ab", () => {
    const answer = { person_id: "p-1", suggestion: "reduced", extra_field: "ueberraschung" };
    expect(assertKeysSubset(answer, doorPayload, allowlist)).toBe(false);
  });

  // F2: Normalisierung (Gross/Kleinschreibung) darf einen bekannten Schluessel
  // nicht mehr faelschlich als "erfunden" behandeln.
  it("erkennt einen bekannten Schluessel trotz abweichender Gross/Kleinschreibung", () => {
    const answer = { Person_ID: "p-1", SUGGESTION: "reduced" };
    expect(assertKeysSubset(answer, doorPayload, allowlist)).toBe(true);
  });

  // F2: der ECHTE Ablehnungsfall -- ein verbotener Begriff als Teilwort eines
  // Schluessels, der so nicht auf der Sperrliste ODER Allowlist steht.
  it("lehnt einen Schluessel ab, der einen verbotenen Begriff als Teilwort enthaelt", () => {
    const answer = { person_id: "p-1", person_id_and_pain_level: "hoch" };
    expect(assertKeysSubset(answer, doorPayload, allowlist)).toBe(false);
  });

  it("lehnt einen Schluessel mit verbotenem Begriff ab, SELBST wenn er sonst durch die Allowlist gedeckt waere", () => {
    // "notes" steht nicht auf der Allowlist, aber selbst wenn eine Allowlist
    // ihn versehentlich zuliesse, muss die Substring-Sperre trotzdem greifen.
    const wideAllowlist = [...allowlist, "clinical_notes"] as const;
    const answer = { clinical_notes: "Freitext" };
    expect(assertKeysSubset(answer, doorPayload, wideAllowlist)).toBe(false);
  });
});

describe("assertValueProvenance", () => {
  const doorPayload = [
    { ref: "A01", person_id: "person-a", band: "low" },
    { ref: "A02", person_id: "person-b", band: "high" },
  ];

  it("laesst einen Wert durch, der aus dem EIGENEN Tuer-Eintrag desselben ref stammt", () => {
    const answer = [{ ref: "A01", person_id: "person-a" }];
    expect(assertValueProvenance(answer, doorPayload, "ref")).toBe(true);
  });

  // Der eigentliche F2-Bug: ein Wert von Person B durfte vorher faelschlich
  // als "stammt aus dem Payload" fuer Person A durchgehen, weil nur global
  // geprueft wurde, ob der Wert IRGENDWO vorkam. Jetzt: gebunden an ref.
  it("lehnt einen Wert ab, der von einem ANDEREN ref/einer anderen Person stammt", () => {
    const answer = [{ ref: "A01", person_id: "person-b" }]; // person-b gehoert zu ref A02, nicht A01
    expect(assertValueProvenance(answer, doorPayload, "ref")).toBe(false);
  });

  it("lehnt einen answer-Eintrag mit unbekanntem/erfundenem ref ab", () => {
    const answer = [{ ref: "A99", person_id: "person-a" }];
    expect(assertValueProvenance(answer, doorPayload, "ref")).toBe(false);
  });

  it("lehnt einen answer-Eintrag ohne (oder mit nicht-stringem) idKey-Feld ab", () => {
    expect(assertValueProvenance([{ person_id: "person-a" }], doorPayload, "ref")).toBe(false);
    expect(assertValueProvenance([{ ref: 123, person_id: "person-a" }], doorPayload, "ref")).toBe(false);
  });

  it("laesst eine leere Antwort durch (nichts zu pruefen)", () => {
    expect(assertValueProvenance([], doorPayload, "ref")).toBe(true);
  });
});

// N1 (Security-Re-Review, zweite Fixrunde): run.ts rief vorher
// g01Violations(JSON.stringify(outcome.body)) auf -- das prueft damit auch
// jeden Schluesselnamen, nicht nur Werte. Eine echte JEV-Choice-Antwort hat
// die Form { choice, probabilities: {...}, confidence }; "probabilities"
// enthaelt den G-01-Begriff "probab" als Teilstring und loeste damit IMMER
// faelschlich aus. g01ViolationsInStringValues prueft NUR String-Blattwerte.
describe("g01ViolationsInStringValues", () => {
  it("ein Schluessel wie 'probabilities' loest G-01 NICHT aus, wenn kein Wert einen Sperrbegriff enthaelt", () => {
    const body = {
      answers: {
        A01: { choice: "reduced", probabilities: { full: 0.05, reduced: 0.9, unclear: 0.05 }, confidence: 0.9 },
      },
      usage: { cost: 0.0001, input_tokens: 100, output_tokens: 5 },
    };
    expect(g01ViolationsInStringValues(body)).toEqual([]);
  });

  it("ein Sperrbegriff als tatsaechlicher STRING-WERT loest G-01 weiterhin aus", () => {
    const body = {
      answers: { A01: { choice: "reduced", confidence: 0.9 } },
      note: "hohes Verletzungsrisiko",
    };
    expect(g01ViolationsInStringValues(body)).toEqual(expect.arrayContaining(["verletz", "risiko"]));
  });

  it("prueft nur String-Blattwerte, keine Zahlen/Booleans/Schluesselnamen", () => {
    // "value" waere z.B. als SCHLUESSEL kein G-01-Begriff (nur "probab" o.ae.
    // sind das), aber diese Probe stellt trotzdem sicher: nur echte
    // String-Werte fliessen in die Pruefung ein, keine Zahlen/Booleans.
    const body = { score: 42, risky: true, values: [1, 2, 3] };
    expect(g01ViolationsInStringValues(body)).toEqual([]);
  });
});
