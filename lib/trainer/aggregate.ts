// Team Performance OS — Aggregation & Label-Logik (Trainer-Frontend).
// REINE Aggregation/Formatierung, KEINE Score-Berechnung. Alle Werte (readiness,
// factors, baseline) kommen unverändert aus dem Coach-Payload (Modul Readiness Score).

import type {
  AttendanceStatus,
  KaderMember,
  MedicalStatus,
  ReadinessFactors,
  TodayEvent,
} from "./types";

const LOW_READINESS_THRESHOLD = 60;
const STRONG_BASELINE_DROP_PCT = -15;

export const FACTOR_ORDER: (keyof ReadinessFactors)[] = [
  "sleep",
  "recovery",
  "mental",
  "muscle",
  "load",
];

export const factorLabels: Record<keyof ReadinessFactors, string> = {
  sleep: "Schlaf",
  recovery: "Erholung",
  mental: "Mental",
  muscle: "Muskulatur",
  load: "Belastung",
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

export function medicalClearanceLabel(
  clearance: KaderMember["medicalClearance"],
): string | null {
  return clearance ? MEDICAL_CLEARANCE_LABELS[clearance] : null;
}

// Deskriptive Abweichung zum rollenden 4-Wo.-Schnitt in Prozent. null, wenn kein
// heutiger Readiness-Wert vorliegt (kein Check-in) oder keine Baseline berechenbar ist.
export function baselineDeviationPct(member: KaderMember): number | null {
  const { value } = member.readiness;
  const { rollingAvg } = member.baseline;
  if (value === null || !rollingAvg) return null;
  return Math.round(((value - rollingAvg) / rollingAvg) * 100);
}

// Auffälligkeits-Zustand: niedrige Readiness ODER medicalStatus != green ODER
// starker Baseline-Drop. Rein deskriptiv, KEINE Diagnose/Risiko-Aussage.
export function isAuffaellig(member: KaderMember): boolean {
  const lowReadiness =
    member.readiness.value !== null &&
    member.readiness.value < LOW_READINESS_THRESHOLD;
  const medicalFlag = member.medicalStatus !== "green";
  const deviation = baselineDeviationPct(member);
  const strongBaselineDrop =
    deviation !== null && deviation <= STRONG_BASELINE_DROP_PCT;
  return lowReadiness || medicalFlag || strongBaselineDrop;
}
