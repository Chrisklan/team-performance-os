// Team Performance OS — Daten-Layer (Trainer-Frontend, Coach-Rolle).
//
// Ruft rpc_morning_ops() auf (RLS-gesichert, app_role='coach'/'athletic_coach').
// Liefert den Kader-Payload NACH dem RLS-Gate: Medical-Inhalte reduziert auf
// Badge + Freigabe. Die Roh-Tabellen medical_records
// (diagnosis/symptoms/treatment/reha_phase) sind im Coach-Payload NICHT enthalten.
// Bei jedem Fehler (kein Supabase-Env, RPC-Fehler, FORBIDDEN) fällt der Layer auf
// die Fixtures zurück, damit das Dashboard im Pilot-Stand nie hart bricht.

import { createServerClient } from "@/lib/supabase/client";
import { seedKader } from "./fixtures";
import type { CoachKaderPayload } from "./types";

// Medical-Diagnose-Felder, die im Coach-Payload NIEMALS auftauchen dürfen (RLS-Test).
export const FORBIDDEN_MEDICAL_KEYS = [
  "diagnosis",
  "symptoms",
  "treatment",
  "reha_phase",
] as const;

export async function fetchKaderForCoach(): Promise<CoachKaderPayload> {
  try {
    const supabase = createServerClient();
    const { data, error } = await supabase.rpc("rpc_morning_ops");

    if (error || !data) {
      throw error ?? new Error("rpc_morning_ops returned no data");
    }

    return data as CoachKaderPayload;
  } catch (err) {
    console.warn(
      "fetchKaderForCoach: rpc_morning_ops fehlgeschlagen, falle auf Fixtures zurück.",
      err,
    );
    return seedKader;
  }
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
