// Team Performance OS — Daten-Layer (Trainer-Frontend, Coach-Rolle).
//
// Simuliert die RLS-gesicherte Supabase-Abfrage für app_role='coach'.
// Liefert den Kader-Payload NACH dem RLS-Gate: Medical-Inhalte reduziert auf
// Badge + Freigabe (medical_status_view). Die Roh-Tabellen medical_records
// (diagnosis/symptoms/treatment/reha_phase) sind im Coach-Payload NICHT enthalten.
//
// Der spätere echte Code ersetzt diese Funktion durch einen Supabase-Select, der
// nur medical_status_view (nicht medical_records) joined. Die Form des Rückgabe-
// typs (CoachKaderPayload) bleibt identisch -> UI unverändert.

import { seedKader } from "./fixtures";
import type { CoachKaderPayload } from "./types";

// Medical-Diagnose-Felder, die im Coach-Payload NIEMALS auftauchen dürfen (RLS-Test).
export const FORBIDDEN_MEDICAL_KEYS = [
  "diagnosis",
  "symptoms",
  "treatment",
  "reha_phase",
] as const;

export function fetchKaderForCoach(): CoachKaderPayload {
  // Im Scaffold: Seed-Daten. Produktion: Supabase-Query mit app_role='coach',
  // die medical_status_view joint (kein Zugriff auf medical_records-Basiszeile).
  return seedKader;
}

// RLS-Verifikation: liefert true, wenn der serialisierte Coach-Payload keine
// verbotenen Medical-Schlüssel enthält. Wird im Build-Verification-Schritt genutzt.
export function coachPayloadIsRlsClean(payload: CoachKaderPayload): {
  clean: boolean;
  violations: string[];
} {
  const serialized = JSON.stringify(payload);
  const violations = FORBIDDEN_MEDICAL_KEYS.filter((k) =>
    serialized.includes(`"${k}"`),
  );
  return { clean: violations.length === 0, violations };
}
