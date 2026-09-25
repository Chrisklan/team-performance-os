"use server";

// Team Performance OS — Freischalten/Sperren des LoadDeviation Moduls fuer das
// Team (Bridge Punkt 77b, ModuleFlagPanel, Modul-LoadDeviation.md Abschnitt 4/6).
// Ruft public.rpc_set_module_flag. Der Backend Rumpf (app.rpc_set_module_flag)
// prueft dieselbe Regel ein zweites Mal und lehnt jede Rolle ausser doctor mit
// FORBIDDEN ab (app.deny, HTTP 403 ueber die Tuer) -- diese Datei prueft die
// Rolle nicht vorher, das ModuleFlagPanel wird server-seitig nur fuer doctor
// gerendert (siehe app/(medizin)/medizin/page.tsx).
//
// Kein stiller Fallback: ein Fehlschlag wird als Fehler zurueckgegeben. Bei
// Erfolg revalidatePath, damit die Kaderliste und alle LoadDeviation Ansichten
// (MODULE_DISABLED) den neuen Zustand beim naechsten Rendern zeigen.

import { revalidatePath } from "next/cache";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { LOAD_DEVIATION_FLAG } from "./types";

export type SetModuleFlagResult = { ok: true; enabled: boolean } | { ok: false; message: string };

export async function setLoadDeviationFlag(enabled: boolean): Promise<SetModuleFlagResult> {
  const supabase = createSupabaseServerClient();
  const { data, error, status } = await supabase.rpc("rpc_set_module_flag", {
    p_flag: LOAD_DEVIATION_FLAG,
    p_enabled: enabled,
  });

  if (error) {
    const classified = classifyRpcError(error, status);
    return { ok: false, message: classified.message };
  }

  revalidatePath("/medizin");
  const row = data as { enabled?: unknown } | null;
  return { ok: true, enabled: typeof row?.enabled === "boolean" ? row.enabled : enabled };
}
