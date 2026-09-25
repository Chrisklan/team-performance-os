"use server";

// Team Performance OS — Freigeben/Verwerfen einer LoadDeviation (Modul 5, Bridge
// Punkt 57 Teil 3). Erste schreibende Interaktion der Medizinsicht im Web.
//
// Ruft public.rpc_review_deviation (physio/doctor, bestehende Tuer aus AP-47a/57,
// unveraendert in dieser Session). Die Tuer antwortet auf eine Ablehnung mit HTTP
// 403 und auf eine unbekannte oder fremde Zeile mit HTTP 404 (P0002, Punkt 64) —
// beides kommt bei supabase-js als `error` an, classifyRpcError ordnet es ein.
//
// Kein stiller Fallback: ein Fehlschlag wird als Fehler zurueckgegeben, nie
// verschluckt. Bei Erfolg revalidatePath, damit die Seite den neuen Zustand
// (state, reviewed_at) beim naechsten Rendern zeigt.

import { revalidatePath } from "next/cache";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";

export type ReviewDeviationDecision = "release" | "dismiss";

export type ReviewDeviationResult = { ok: true } | { ok: false; message: string };

export async function reviewDeviation(
  personId: string,
  deviationId: string,
  decision: ReviewDeviationDecision,
): Promise<ReviewDeviationResult> {
  const supabase = createSupabaseServerClient();
  const { error, status } = await supabase.rpc("rpc_review_deviation", {
    p_deviation_id: deviationId,
    p_decision: decision,
  });

  if (error) {
    const classified = classifyRpcError(error, status);
    return { ok: false, message: classified.message };
  }

  revalidatePath(`/medizin/${personId}`);
  return { ok: true };
}
