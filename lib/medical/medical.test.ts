import { describe, expect, it } from "vitest";
import { countPhrase, dayAxis, regionsOfBodyMap, reportedDaysByRegion } from "./bodymap";
import { clearanceLabel, deviationPersistence, shortDate, sleepHours, valueOrDot } from "./format";
import { appRoleFromClaims, homePathForRole, isMedicalRole, isUuid } from "./role";
import type { CheckinDay } from "./types";

describe("Rolle aus den Claims", () => {
  it("liest app_role", () => {
    expect(appRoleFromClaims({ app_role: "physio", sub: "x" })).toBe("physio");
  });
  it("ohne Claim oder mit falschem Typ: null", () => {
    expect(appRoleFromClaims(undefined)).toBeNull();
    expect(appRoleFromClaims({ app_role: 7 })).toBeNull();
    expect(appRoleFromClaims({ app_role: "" })).toBeNull();
  });
  it("nur physio und doctor sind Medizin, admin und coach nicht", () => {
    expect(isMedicalRole("physio")).toBe(true);
    expect(isMedicalRole("doctor")).toBe(true);
    for (const r of ["coach", "athletic_coach", "admin", "player", null]) {
      expect(isMedicalRole(r)).toBe(false);
    }
  });
  it("Startseite je Rolle", () => {
    expect(homePathForRole("doctor")).toBe("/medizin");
    expect(homePathForRole("coach")).toBe("/dashboard");
    expect(homePathForRole(null)).toBe("/dashboard");
  });
  it("nur UUIDs gehen an die Tuer", () => {
    expect(isUuid("a0000000-0000-0000-0000-000000000005")).toBe(true);
    expect(isUuid("../dashboard")).toBe(false);
    expect(isUuid("a0000000-0000-0000-0000-00000000000")).toBe(false);
  });
});

const day = (date: string, body_map: unknown): CheckinDay => ({
  id: date, date, body_map, sleep_duration_min: null, sleep_quality: null, recovery: null,
  energy: null, mental_stress: null, mental_mood: null, mental_motivation: null,
  training_readiness: null, pain_max: null, submitted_at: null,
});

describe("Body Map Zaehlung", () => {
  it("Tagesachse schliesst beide Enden ein, auch ueber die Zeitumstellung", () => {
    const axis = dayAxis("2026-10-20", "2026-10-27");
    expect(axis).toHaveLength(8);
    expect(axis[0]).toBe("2026-10-20");
    expect(axis.at(-1)).toBe("2026-10-27");
    expect(dayAxis("2026-09-01", "2026-09-28")).toHaveLength(28);
  });
  it("Array Form: Regionen ohne Doppel, Tippunkt wird ignoriert", () => {
    expect(
      regionsOfBodyMap([
        { region: "knie_l", pain: 4, point: [0.1, 0.2] },
        { region: "knie_l", pain: 2 },
        { region: "ruecken", pain: null },
        { pain: 3 },
      ]),
    ).toEqual(["knie_l", "ruecken"]);
  });
  it("alte Objektform und leere Werte", () => {
    expect(regionsOfBodyMap({ knie_l: 6 })).toEqual(["knie_l"]);
    expect(regionsOfBodyMap(null)).toEqual([]);
    expect(regionsOfBodyMap([])).toEqual([]);
  });
  it("Tage je Region und Tage mit Check-in", () => {
    const { answered, byRegion } = reportedDaysByRegion([
      day("2026-09-20", [{ region: "knie_l", pain: 3 }]),
      day("2026-09-21", []),
      day("2026-09-22", [{ region: "knie_l", pain: 5 }, { region: "ruecken", pain: 1 }]),
    ]);
    expect(answered.size).toBe(3);
    expect([...(byRegion.get("knie_l") ?? [])]).toEqual(["2026-09-20", "2026-09-22"]);
    expect(byRegion.get("ruecken")?.size).toBe(1);
  });
  it("zaehlend formuliert, nie Prozent", () => {
    expect(countPhrase(4, 21)).toBe("an 4 von 21 Tagen");
    expect(countPhrase(1, 1)).toBe("an 1 von 1 Tag");
    expect(countPhrase(4, 21)).not.toContain("%");
  });
});

describe("Format ohne Striche", () => {
  it("fehlender Wert ist ein Mittelpunkt, kein Strich", () => {
    expect(valueOrDot(null)).toBe("·");
    expect(sleepHours(null)).toBe("·");
    expect(valueOrDot(0)).toBe("0");
  });
  it("Schlaf, Datum, Freigabe", () => {
    expect(sleepHours(450)).toBe("7:30 h");
    expect(shortDate("2026-09-22")).toBe("Di 22.09.");
    expect(clearanceLabel("blocked")).toBe("Gesperrt");
  });
  it("Persistenzzähler ohne Bewertung, kein Text ohne Wert", () => {
    expect(deviationPersistence(4)).toBe("4 von 7 Tagen außerhalb der Norm");
    expect(deviationPersistence(0)).toBe("0 von 7 Tagen außerhalb der Norm");
    expect(deviationPersistence(null)).toBeNull();
  });
});
