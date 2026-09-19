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
// Die Seite faengt KaderAccessError ab und zeigt je Code einen eigenen Zustand
// (components/trainer/KaderStateScreen.tsx). Warum nicht error.tsx: Next.js entfernt in
// Produktion Message und Felder von Server-Component-Fehlern, der Code kaeme nie an.

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { KaderAccessError, classifyRpcError } from "./errors";
import type { CoachKaderPayload } from "./types";

export { KaderAccessError, classifyRpcError } from "./errors";
export type { KaderErrorCode } from "./errors";

// Medical-Diagnose-Felder, die im Coach-Payload NIEMALS auftauchen dürfen (RLS-Test).
export const FORBIDDEN_MEDICAL_KEYS = [
  "diagnosis",
  "symptoms",
  "treatment",
  "reha_phase",
] as const;

export async function fetchKaderForCoach(): Promise<CoachKaderPayload> {
  const supabase = createSupabaseServerClient();

  // Serverseitig gegen den Auth-Server geprueft, kein Aufruf ohne Login.
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError?.name === "AuthRetryableFetchError") {
    throw new KaderAccessError("Auth-Server nicht erreichbar.", "NETWORK");
  }
  if (userError || !user) {
    throw new KaderAccessError("Nicht angemeldet.", "UNAUTHENTICATED");
  }

  const { data, error, status } = await supabase.rpc("rpc_trainer_morning_ops");

  if (error) {
    throw classifyRpcError(error, status);
  }
  if (!data) {
    throw new KaderAccessError("Kader-Payload ist leer.", "RPC_FAILED", "empty_payload");
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
