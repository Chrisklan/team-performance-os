// Team Performance OS — Body Map Zaehlung fuer die Medizinsicht (rein, testbar).
//
// Regeln aus Modul Body-Map Abschnitt 7.3 und 8, die die Datenbank nicht
// erzwingt und deshalb hier stehen:
//  * nur zaehlen: an welchen Tagen eine Region gemeldet wurde, nie wie stark
//    in Farbe oder Hoehe
//  * der Tippunkt wird nie gelesen, auch nicht zum Zaehlen
//  * keine Links Rechts Paarung, keine eigene Sortierung (die Tuer liefert die
//    Katalogreihenfolge)

import type { CheckinDay } from "./types";

// Alle Kalendertage von from bis to (beide einschliesslich), als YYYY-MM-DD.
// Rechnet in UTC, damit keine Sommerzeitumstellung einen Tag verschluckt.
export function dayAxis(from: string, to: string): string[] {
  const start = Date.parse(`${from}T00:00:00Z`);
  const end = Date.parse(`${to}T00:00:00Z`);
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return [];
  const days: string[] = [];
  for (let t = start; t <= end; t += 86_400_000) {
    days.push(new Date(t).toISOString().slice(0, 10));
  }
  return days;
}

// Die Regionen eines Check-ins, unabhaengig von der Form. Zaehlt nur Eintraege
// mit einem Regionsschluessel. "keine Beschwerden" ist ein leeres body_map.
export function regionsOfBodyMap(bodyMap: unknown): string[] {
  if (Array.isArray(bodyMap)) {
    const keys = bodyMap
      .map((entry) =>
        entry && typeof entry === "object" ? (entry as Record<string, unknown>).region : null,
      )
      .filter((region): region is string => typeof region === "string" && region.length > 0);
    return Array.from(new Set(keys));
  }
  if (bodyMap && typeof bodyMap === "object") {
    return Object.keys(bodyMap as Record<string, unknown>);
  }
  return [];
}

// Je Region die Tage, an denen sie gemeldet wurde. Dazu die Tage mit Check-in.
export function reportedDaysByRegion(checkins: CheckinDay[]): {
  answered: Set<string>;
  byRegion: Map<string, Set<string>>;
} {
  const answered = new Set<string>();
  const byRegion = new Map<string, Set<string>>();
  for (const day of checkins) {
    answered.add(day.date);
    for (const region of regionsOfBodyMap(day.body_map)) {
      const days = byRegion.get(region) ?? new Set<string>();
      days.add(day.date);
      byRegion.set(region, days);
    }
  }
  return { answered, byRegion };
}

// "an 4 von 21 Tagen", nie als Prozent (Modul Body-Map 7.3).
export function countPhrase(count: number, of: number): string {
  return `an ${count} von ${of} ${of === 1 ? "Tag" : "Tagen"}`;
}
