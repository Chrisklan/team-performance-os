// Team Performance OS — Formatierung der Medizinsicht (rein, testbar). Keine Bindestriche in UI Copy.

import type { ClearanceStatus } from "./types";

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
