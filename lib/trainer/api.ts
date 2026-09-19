// Team Performance OS — Daten-Layer (Trainer-Frontend, Coach-Rolle).
//
// Ruft public.rpc_trainer_morning_ops() mit dem JWT des angemeldeten Users auf.
// Die Tuer ist SECURITY INVOKER und reicht an app.rpc_morning_ops() durch
// (Waechter Stufe 2, ADR-015): Trainer bekommt seinen Kader, alle anderen FORBIDDEN.
// Liefert den Kader-Payload NACH dem Gate: Medical-Inhalte reduziert auf
// Badge + Freigabe. Die Roh-Tabellen medical_records
// (diagnosis/symptoms/treatment/reha_phase) sind im Coach-Payload NICHT enthalten.
//
// Kein stiller Fallback: jeder Fehler wird geworfen (SESSION-BRIDGE Regel 2).
// Die Fehleroberflaeche baut AP-31.

import { createSupabaseServerClient } from "@/lib/supabase/server";
import type { CoachKaderPayload } from "./types";

// Medical-Diagnose-Felder, die im Coach-Payload NIEMALS auftauchen dürfen (RLS-Test).
export const FORBIDDEN_MEDICAL_KEYS = [
  "diagnosis",
  "symptoms",
  "treatment",
  "reha_phase",
] as const;

export class KaderAccessError extends Error {
  constructor(
    message: string,
    readonly code: "UNAUTHENTICATED" | "FORBIDDEN" | "RPC_FAILED",
  ) {
    super(message);
    this.name = "KaderAccessError";
  }
}

export async function fetchKaderForCoach(): Promise<CoachKaderPayload> {
  const supabase = createSupabaseServerClient();

  // Serverseitig gegen den Auth-Server geprueft, kein Aufruf ohne Login.
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError || !user) {
    throw new KaderAccessError("Nicht angemeldet.", "UNAUTHENTICATED");
  }

  const { data, error } = await supabase.rpc("rpc_trainer_morning_ops");

  if (error) {
    if (error.code === "42501") {
      throw new KaderAccessError("Kein Zugriff auf den Kader.", "FORBIDDEN");
    }
    throw new KaderAccessError(
      `Kader konnte nicht geladen werden (${error.code ?? "unbekannt"}).`,
      "RPC_FAILED",
    );
  }
  if (!data) {
    throw new KaderAccessError("Kader-Payload ist leer.", "RPC_FAILED");
  }

  return data as CoachKaderPayload;
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
