// Team Performance OS — Aggregation & Label-Logik (Trainer-Frontend).
// REINE Aggregation/Formatierung, KEINE Score-Berechnung. Alle Werte (readiness,
// factors, baseline) kommen unverändert aus dem Coach-Payload (Modul Readiness Score).

import type {
  AttendanceStatus,
  KaderMember,
  MedicalStatus,
  ReadinessBand,
  TodayEvent,
} from "./types";

// Reihenfolge der Stufen von links nach rechts. Der Meter setzt die Position
// daraus, nicht aus der Farbe.
export const BAND_ORDER: ReadinessBand[] = ["low", "moderate", "high"];

const BAND_LABELS: Record<ReadinessBand, string> = {
  low: "Niedrig",
  moderate: "Mittel",
  high: "Hoch",
};

const ATTENDANCE_LABELS: Record<AttendanceStatus, string> = {
  anwesend: "Anwesend",
  verletzt: "Verletzt",
  reha: "Reha",
  national: "National",
  urlaub: "Urlaub",
  krank: "Krank",
};

const TODAY_EVENT_LABELS: Record<TodayEvent, string> = {
  training: "Training",
  spiel: "Spiel",
  none: "Kein Termin",
};

const MEDICAL_LABELS: Record<MedicalStatus, string> = {
  green: "Grün",
  yellow: "Gelb",
  orange: "Orange",
  red: "Rot",
};

const MEDICAL_CLEARANCE_LABELS: Record<
  NonNullable<KaderMember["medicalClearance"]>,
  string
> = {
  frei: "Freigegeben",
  eingeschraenkt: "Eingeschränkt",
  gesperrt: "Gesperrt",
};

export function attendanceLabel(status: AttendanceStatus): string {
  return ATTENDANCE_LABELS[status];
}

export function todayEventLabel(event: TodayEvent): string {
  return TODAY_EVENT_LABELS[event];
}

export function medicalLabel(status: MedicalStatus): string {
  return MEDICAL_LABELS[status];
}

export function bandLabel(band: ReadinessBand): string {
  return BAND_LABELS[band];
}

export function medicalClearanceLabel(
  clearance: KaderMember["medicalClearance"],
): string | null {
  return clearance ? MEDICAL_CLEARANCE_LABELS[clearance] : null;
}

// Auffälligkeits-Zustand: Band niedrig ODER medicalStatus != green.
// Rein deskriptiv, KEINE Diagnose/Risiko-Aussage.
//
// Die dritte Bedingung von früher, der starke Baseline-Drop, ist mit dem
// Zahlwert weggefallen: sie rechnete readiness.value gegen den rollenden
// Schnitt, und genau diese Differenz ist das Inferenz-Leck aus Modul
// Abschnitt 3 (aus dem täglichen Delta liest ein Trainer den Verletzungs-
// beginn ab). Sie kommt nicht in anderer Form zurück.
export function isAuffaellig(member: KaderMember): boolean {
  return member.readiness.band === "low" || member.medicalStatus !== "green";
}
