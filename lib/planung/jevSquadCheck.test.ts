import { describe, expect, it } from "vitest";
import {
  JEV_CHOICES,
  buildJevRequest,
  mergeOverlays,
  overlaysFromRefs,
  validateJevAnswers,
} from "./jevSquadCheck";
import type { JevContext, SquadAthlete } from "./types";

const ctx: JevContext = {
  call_id: 7,
  provider: "openrouter",
  model: "typesafe/jev-1.13",
  rule_version: "v1",
  session: { duration_min: 60, planned_intensity: 6, session_type: "field" },
  candidates: [
    { ref: "A01", band: "low", planned_load_vs_own_norm: "normal", released_deviations_7d: [] },
    { ref: "A02", band: "high", planned_load_vs_own_norm: "above", released_deviations_7d: ["session_load.above"] },
  ],
  refs: [
    { ref: "A01", person_id: "p-1" },
    { ref: "A02", person_id: "p-2" },
  ],
};

function athlete(partial: Partial<SquadAthlete> & { person_id: string }): SquadAthlete {
  return {
    display_name: "X",
    jersey: null,
    suggestion: "full",
    source: "rule",
    clearance: "full",
    band: "high",
    load_level: "normal",
    released_deviation_keys: [],
    has_checkin: true,
    hints: [],
    dismissed_hints: [],
    ...partial,
  };
}

const REFS = ["A01", "A02"];

describe("buildJevRequest", () => {
  it("baut state nur aus Kandidaten und Session, ohne refs/person_id", () => {
    const req = buildJevRequest(ctx)!;
    const text = JSON.stringify(req);
    expect(text).not.toContain("person_id");
    expect(text).not.toContain("p-1");
    expect(Object.keys(req.state)).toEqual(["session", "athletes"]);
    expect(Object.keys(req.state.athletes[0]).sort()).toEqual(
      ["band", "planned_load_vs_own_norm", "ref", "released_deviations_7d"],
    );
    expect(Object.keys(req.questions)).toEqual(["A01", "A02"]);
  });

  it("uebernimmt ein spaeter hinzugefuegtes Feld der Tuer nicht still", () => {
    const leaky = {
      ...ctx,
      candidates: [{ ...ctx.candidates[0], display_name: "Name", person_id: "p-1", score_total: 3 } as never],
    };
    const text = JSON.stringify(buildJevRequest(leaky));
    expect(text).not.toContain("display_name");
    expect(text).not.toContain("score_total");
    expect(text).not.toContain("person_id");
  });

  it("kennt nur full/reduced/unclear, nie individual oder aussetzen", () => {
    const req = buildJevRequest(ctx)!;
    const q = req.questions.A01;
    expect(q.type).toBe("choice");
    expect(Object.keys(q.criteria)).toEqual([...JEV_CHOICES]);
    const text = JSON.stringify(req.questions).toLowerCase();
    expect(text).not.toContain("individual");
    expect(text).not.toContain("suspend");
    expect(text).not.toContain("aussetzen");
    expect(q.instructions.question).toContain("athletes[ref=A01]");
    expect(q.instructions.inspect).toBe("athletes[ref=A01]");
  });

  it("liefert null ohne Kandidaten oder ohne Session", () => {
    expect(buildJevRequest({ ...ctx, candidates: [] })).toBeNull();
    expect(buildJevRequest({ ...ctx, session: undefined })).toBeNull();
  });
});

describe("validateJevAnswers", () => {
  it("nimmt reduced nur ab Schwelle und nur als Zahl", () => {
    const res = validateJevAnswers(
      { answers: { A01: { choice: "reduced", confidence: 0.9 }, A02: { choice: "reduced", confidence: 0.5 } } },
      REFS,
      0.7,
    );
    expect(res.reducedRefs).toEqual(["A01"]);
    expect(res.resultClass).toBe("ok");
  });

  it("full und unclear aendern nichts", () => {
    const res = validateJevAnswers(
      { answers: { A01: { choice: "full", confidence: 0.99 }, A02: { choice: "unclear", confidence: 0.99 } } },
      REFS,
      0.7,
    );
    expect(res.reducedRefs).toEqual([]);
    expect(res.resultClass).toBe("ok");
  });

  it("Werte ausserhalb der Menge zaehlen nicht (auch individual/suspend/Grossschreibung)", () => {
    const res = validateJevAnswers(
      {
        answers: {
          A01: { choice: "individual", confidence: 0.99 },
          A02: { choice: "Reduced", confidence: 0.99 },
        },
      },
      REFS,
      0.7,
    );
    expect(res.reducedRefs).toEqual([]);
    expect(res.resultClass).toBe("invalid");
  });

  it("Noul- und Score-Formen sind fuer diese Frage ungueltig", () => {
    const res = validateJevAnswers(
      {
        answers: {
          A01: { noul: 0.95 },
          A02: { score: 2, legend: ["a", "b", "c"], confidence: 0.9 },
        },
      },
      REFS,
      0.7,
    );
    expect(res.reducedRefs).toEqual([]);
    expect(res.resultClass).toBe("invalid");
  });

  it("Konfidenz als String, NaN oder ausserhalb 0..1 zaehlt nicht", () => {
    for (const confidence of ["0.9", Number.NaN, 1.5, -0.1, null]) {
      const res = validateJevAnswers(
        { answers: { A01: { choice: "reduced", confidence }, A02: { choice: "full", confidence: 0.9 } } },
        REFS,
        0.7,
      );
      expect(res.reducedRefs).toEqual([]);
      expect(res.resultClass).toBe("partial");
    }
  });

  it("fremde refs werden ignoriert, fehlende refs machen partial", () => {
    const res = validateJevAnswers(
      { answers: { A99: { choice: "reduced", confidence: 1 }, A01: { choice: "reduced", confidence: 0.8 } } },
      REFS,
      0.7,
    );
    expect(res.reducedRefs).toEqual(["A01"]);
    expect(res.resultClass).toBe("partial");
  });

  it("kaputte Antworten sind invalid", () => {
    for (const body of [null, "text", 42, [], {}, { answers: null }, { answers: [] }, { answers: "x" }]) {
      const res = validateJevAnswers(body, REFS, 0.7);
      expect(res.reducedRefs).toEqual([]);
      expect(res.resultClass).toBe("invalid");
    }
  });

  it("Prototyp-Schluessel werden nicht als Antwort gelesen", () => {
    const res = validateJevAnswers({ answers: {} }, ["constructor", "toString"], 0.7);
    expect(res.reducedRefs).toEqual([]);
    expect(res.resultClass).toBe("invalid");
  });
});

describe("overlaysFromRefs", () => {
  it("uebersetzt nur bekannte refs, nie Konfidenz", () => {
    const overlays = overlaysFromRefs(["A02", "A77"], ctx.refs);
    expect(overlays).toEqual([{ person_id: "p-2", suggestion: "reduced", hint_key: "j1", source: "jev" }]);
    expect(JSON.stringify(overlays)).not.toContain("confidence");
  });
});

describe("mergeOverlays", () => {
  const athletes: SquadAthlete[] = [
    athlete({ person_id: "p-1", hints: ["h1"] }),
    athlete({ person_id: "p-2", suggestion: "suspend", source: "mirror", clearance: "blocked" }),
    athlete({ person_id: "p-3", suggestion: "individual", source: "mirror", clearance: "individual" }),
    athlete({ person_id: "p-4", suggestion: "reduced", source: "mirror", clearance: "limited" }),
    athlete({ person_id: "p-5", suggestion: "reduced", source: "rule", hints: ["h1", "h2"] }),
    athlete({ person_id: "p-6", hints: ["h1"], dismissed_hints: ["j1"] }),
  ];
  const all = ["p-1", "p-2", "p-3", "p-4", "p-5", "p-6"].map((person_id) => ({
    person_id,
    suggestion: "reduced",
    hint_key: "j1",
    source: "jev",
  }));

  it("hebt nur volle Gruppe aus Quelle rule auf reduziert", () => {
    const merged = mergeOverlays(athletes, all);
    expect(merged.find((a) => a.person_id === "p-1")).toMatchObject({ suggestion: "reduced", jev: true });
  });

  it("veraendert Spiegel nie", () => {
    const merged = mergeOverlays(athletes, all);
    expect(merged.find((a) => a.person_id === "p-2")).toMatchObject({ suggestion: "suspend", jev: false });
    expect(merged.find((a) => a.person_id === "p-3")).toMatchObject({ suggestion: "individual", jev: false });
    expect(merged.find((a) => a.person_id === "p-4")).toMatchObject({ suggestion: "reduced", source: "mirror", jev: false });
  });

  it("laesst eine regelseitig eskalierte Person und weggeklicktes j1 unberuehrt", () => {
    const merged = mergeOverlays(athletes, all);
    expect(merged.find((a) => a.person_id === "p-5")).toMatchObject({ suggestion: "reduced", jev: false });
    expect(merged.find((a) => a.person_id === "p-6")).toMatchObject({ suggestion: "full", jev: false });
  });

  it("ignoriert Overlays mit anderem Vorschlag, fremder Quelle oder kaputter Form", () => {
    const merged = mergeOverlays(athletes, [
      { person_id: "p-1", suggestion: "suspend", hint_key: "j1", source: "jev" },
      { person_id: "p-1", suggestion: "individual", hint_key: "j1", source: "jev" },
      { person_id: "p-1", suggestion: "reduced", hint_key: "j1", source: "rule" },
      null,
      "p-1",
    ]);
    expect(merged.find((a) => a.person_id === "p-1")).toMatchObject({ suggestion: "full", jev: false });
  });

  it("erzeugt nie individual oder aussetzen aus JEV", () => {
    const before = athletes.filter((a) => a.suggestion === "individual" || a.suggestion === "suspend").length;
    const merged = mergeOverlays(athletes, all);
    const after = merged.filter((a) => a.suggestion === "individual" || a.suggestion === "suspend").length;
    expect(after).toBe(before);
  });

  it("ohne Overlays bleibt alles beim Regelergebnis v1", () => {
    const merged = mergeOverlays(athletes, []);
    expect(merged.map((a) => a.suggestion)).toEqual(athletes.map((a) => a.suggestion));
    expect(merged.every((a) => a.jev === false)).toBe(true);
  });
});
