// Team Performance OS — Fixtures (lokale Entwicklung, NICHT Produktion).
// Simuliert den Coach-RLS-Payload: liefert KaderMember OHNE Medical-Diagnose-Inhalte.
// Die echte Quelle (medical_records) würde diagnosis/symptoms/treatment/reha_phase
// enthalten — diese werden im Backend via medical_status_view auf das Badge reduziert.
// Der Daten-Layer hier bildet den Post-RLS-Zustand ab (Badge + Freigabe), exakt wie
// die spätere Supabase-Abfrage mit app_role='coach'.
//
// WICHTIG für RLS-Test: Das Objekt enthält bewusst KEINE Schlüssel
// diagnosis / symptoms / treatment / reha_phase. Ein Grep über den serialisierten
// Coach-Payload (siehe lib/trainer/api.ts fetchKaderForCoach) muss leer bleiben.

import type {
  CoachKaderPayload,
  KaderMember,
  MedicalStatus,
  ReadinessBand,
} from "./types";

function member(
  id: string,
  jersey: number,
  name: string,
  position: string,
  band: ReadinessBand | null,
  baselineSeries: number[],
  medicalStatus: MedicalStatus,
  medicalClearance: "frei" | "eingeschraenkt" | "gesperrt" | null,
  attendance: KaderMember["attendance"],
  todayEvent: KaderMember["todayEvent"],
): KaderMember {
  return {
    player: { id, jersey, name, position },
    readiness: { band },
    baseline: {
      series: baselineSeries,
      rollingAvg:
        baselineSeries.reduce((s, v) => s + v, 0) / baselineSeries.length,
    },
    medicalStatus,
    medicalClearance,
    attendance,
    todayEvent,
    hasCheckIn: band !== null,
  };
}

export const seedKader: CoachKaderPayload = {
  kaderName: "BSV Buxtehude — 1. Bundesliga Kader",
  syncState: "live",
  asOf: new Date().toISOString().slice(0, 10),
  members: [
    member("p07", 7, "Müller", "LA", "high", [79, 81, 80, 82, 83, 81, 82], "green", "frei", "anwesend", "training"),
    member("p11", 11, "Costa", "RA", "low", [78, 76, 74, 70, 66, 62, 58], "yellow", "eingeschraenkt", "anwesend", "training"),
    member("p04", 4, "Becker", "IV", null, [80, 81, 82, 80, 81, 80, 81], "green", "frei", "urlaub", "none"),
    member("p09", 9, "Nowak", "ST", "moderate", [72, 73, 71, 70, 72, 73, 74], "green", "frei", "anwesend", "spiel"),
    member("p02", 2, "Schulz", "RV", "moderate", [75, 74, 73, 72, 70, 69, 68], "green", "frei", "anwesend", "training"),
    member("p10", 10, "Vidal", "ZM", "low", [70, 71, 69, 67, 64, 60, 56], "orange", "eingeschraenkt", "verletzt", "training"),
    member("p03", 3, "Koch", "IV", "high", [84, 85, 83, 86, 87, 85, 88], "green", "frei", "anwesend", "training"),
    member("p06", 6, "Larsen", "DM", "moderate", [74, 75, 76, 75, 77, 76, 75], "green", "frei", "anwesend", "training"),
    member("p01", 1, "Hoffmann", "TW", "moderate", [70, 71, 69, 72, 71, 70, 69], "green", "frei", "anwesend", "training"),
    member("p08", 8, "Yilmaz", "LF", null, [77, 78, 76, 79, 78, 77, 78], "yellow", "eingeschraenkt", "reha", "none"),
    member("p05", 5, "Brandt", "ZM", "low", [73, 72, 71, 70, 68, 66, 64], "green", "frei", "anwesend", "spiel"),
    member("p12", 12, "Okoro", "RA", "high", [80, 81, 82, 83, 82, 84, 83], "green", "frei", "anwesend", "training"),
    member("p14", 14, "Petrov", "ST", "low", [71, 70, 69, 67, 65, 62, 59], "red", "gesperrt", "verletzt", "none"),
    member("p15", 15, "Andersen", "LV", "moderate", [76, 77, 75, 78, 79, 78, 77], "green", "frei", "national", "none"),
  ],
};
