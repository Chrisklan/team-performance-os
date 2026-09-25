import { describe, expect, it } from "vitest";
import { buildDeviationTeamGroups } from "./deviations";
import type { DeviationsTodayEntry, DeviationsTodayRow } from "./deviations";
import type { KaderMember } from "./types";

function member(id: string, jersey: number, name: string): KaderMember {
  return {
    player: { id, jersey, name, position: "Mittelfeld" },
    readiness: { band: "high" },
    baseline: { series: [], rollingAvg: 0 },
    medicalStatus: "green",
    medicalClearance: null,
    attendance: "anwesend",
    todayEvent: "training",
    hasCheckIn: true,
  };
}

function row(id: string, magnitude: number): DeviationsTodayRow {
  return {
    id,
    metric: "sleep_duration_min",
    deviation_pct: -12.3,
    state: "released",
    magnitude,
    streak_days: 2,
    days_out_7: 4,
    statement_key: "sleep_duration_min.below",
  };
}

describe("buildDeviationTeamGroups", () => {
  const roster = [member("p1", 7, "Anna Beck"), member("p2", 3, "Bea Cott")];

  it("lässt Personen ohne Abweichungen heute weg", () => {
    const entries: DeviationsTodayEntry[] = [{ person_id: "p1", deviations: [] }];
    expect(buildDeviationTeamGroups(entries, roster)).toEqual([]);
  });

  it("verknüpft person_id mit dem Roster für Name und Rückennummer", () => {
    const entries: DeviationsTodayEntry[] = [{ person_id: "p2", deviations: [row("d1", 3)] }];
    const groups = buildDeviationTeamGroups(entries, roster);
    expect(groups).toHaveLength(1);
    expect(groups[0].player.name).toBe("Bea Cott");
    expect(groups[0].player.jersey).toBe(3);
  });

  it("sortiert nach Anzahl der Abweichungen absteigend, dann Rückennummer", () => {
    const entries: DeviationsTodayEntry[] = [
      { person_id: "p1", deviations: [row("d1", 1)] },
      { person_id: "p2", deviations: [row("d2", 5), row("d3", 2)] },
    ];
    const groups = buildDeviationTeamGroups(entries, roster);
    expect(groups.map((g) => g.player.id)).toEqual(["p2", "p1"]);
  });

  it("gleiche Anzahl: Rückennummer entscheidet", () => {
    const roster3 = [...roster, member("p3", 1, "Cara Diehl")];
    const entries: DeviationsTodayEntry[] = [
      { person_id: "p1", deviations: [row("d1", 1)] },
      { person_id: "p3", deviations: [row("d2", 1)] },
    ];
    const groups = buildDeviationTeamGroups(entries, roster3);
    expect(groups.map((g) => g.player.jersey)).toEqual([1, 7]);
  });

  it("unbekannte person_id (nicht im Roster) bekommt einen Platzhalter statt abzustürzen", () => {
    const entries: DeviationsTodayEntry[] = [{ person_id: "ghost", deviations: [row("d1", 1)] }];
    const groups = buildDeviationTeamGroups(entries, roster);
    expect(groups[0].player.name).toBe("Unbekannte Person");
    expect(groups[0].player.id).toBe("ghost");
  });
});
