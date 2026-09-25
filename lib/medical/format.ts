// Team Performance OS — Formatierung der Medizinsicht (rein, testbar). Keine Bindestriche in UI Copy.

import type { ClearanceStatus, DeviationMetric, DeviationState } from "./types";

const CLEARANCE_LABELS: Record<ClearanceStatus, string> = {
  full: "Freigegeben",
  limited: "Eingeschränkt",
  individual: "Individuell",
  blocked: "Gesperrt",
};

export function clearanceLabel(status: ClearanceStatus): string {
  return CLEARANCE_LABELS[status] ?? status;
}

const ROLE_LABELS: Record<string, string> = {
  physio: "Physio",
  doctor: "Ärztin oder Arzt",
};

export function medicalRoleLabel(role: string | null | undefined): string {
  return (role && ROLE_LABELS[role]) || "Unbekannt";
}

const WEEKDAYS = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];

// "Mo 22.09." aus YYYY-MM-DD, ohne Zeitzone (das Datum ist schon ein Kalendertag).
export function shortDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return iso;
  const weekday = WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  return `${weekday} ${String(d).padStart(2, "0")}.${String(m).padStart(2, "0")}.`;
}

// "22.09.2026" aus YYYY-MM-DD.
export function longDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-");
  return y && m && d ? `${d}.${m}.${y}` : iso;
}

// Schlafdauer in Minuten als "7:30 h".
// Fehlender Wert: ein Mittelpunkt statt eines Strichs (keine Striche in UI Copy).
export const NO_VALUE = "·";

export function sleepHours(minutes: number | null): string {
  if (minutes === null || minutes === undefined) return NO_VALUE;
  const h = Math.floor(minutes / 60);
  const min = Math.round(minutes % 60);
  return `${h}:${String(min).padStart(2, "0")} h`;
}

export function valueOrDot(value: number | null | undefined): string {
  return value === null || value === undefined ? NO_VALUE : String(value);
}

const FACTOR_LABELS: Record<string, string> = {
  sleep: "Schlaf",
  recovery: "Erholung",
  energy: "Energie",
  soreness: "Muskelgefühl",
  stress: "Stress",
  mood: "Stimmung",
  motivation: "Motivation",
  pain: "Schmerz",
  load: "Belastung",
};

export function factorLabel(key: string): string {
  return FACTOR_LABELS[key] ?? key;
}

// LoadDeviation (Modul 5). Dieselben deutschen Namen wie CheckinTable, wo die
// Metrik auch dort vorkommt (sleep_duration_min, mental_stress, ...).
const DEVIATION_METRIC_LABELS: Record<DeviationMetric, string> = {
  sleep_duration_min: "Schlafdauer",
  sleep_quality: "Schlafqualität",
  recovery: "Erholung",
  mental_stress: "Stress",
  mental_mood: "Stimmung",
  mental_motivation: "Motivation",
  session_load: "Trainingslast",
  acute_chronic_ratio: "Wochenlast",
  pain_max: "Schmerz höchster",
};

export function deviationMetricLabel(metric: DeviationMetric): string {
  return DEVIATION_METRIC_LABELS[metric] ?? metric;
}

const DEVIATION_STATE_LABELS: Record<DeviationState, string> = {
  unreviewed: "Ungesichtet",
  released: "Freigegeben",
  dismissed: "Verworfen",
};

export function deviationStateLabel(state: DeviationState): string {
  return DEVIATION_STATE_LABELS[state] ?? state;
}

// "+12,3 %" bzw. "−8,0 %" (echtes Minuszeichen, kein Bindestrich). Nur die Zahl,
// keine Bewertung ("ueber/unter der Norm") -- die Deskription bleibt der Tuer
// rpc_get_deviation_statement vorbehalten, die diese Seite nicht aufruft.
export function deviationPercent(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  const formatted = Math.abs(rounded).toFixed(1).replace(".", ",");
  if (rounded > 0) return `+${formatted} %`;
  if (rounded < 0) return `−${formatted} %`;
  return `${formatted} %`;
}

// "4 von 7 Tagen außerhalb der Norm" (Modul-LoadDeviation.md Abschnitt 2,
// Persistenzzaehler days_out_7). Nur die Dauer, keine Bewertung. Fehlender Wert
// (noch keine 7-Tage-Reihe): kein Text statt eines erfundenen Werts.
export function deviationPersistence(daysOut7: number | null): string | null {
  if (daysOut7 === null || daysOut7 === undefined) return null;
  return `${daysOut7} von 7 Tagen außerhalb der Norm`;
}
