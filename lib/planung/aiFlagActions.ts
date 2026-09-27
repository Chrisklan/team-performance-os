"use server";

// Team Performance OS — Team-Schalter fuer die JEV-Zuordnung (AP-69).
// Ruft public.rpc_set_module_flag. Der Backend-Rumpf (app.rpc_set_module_flag,
// backend/41_jev_switch_model_call_log.sql) laesst fuer dieses Flag nur admin
// zu und lehnt jede andere Rolle mit FORBIDDEN ab (app.deny, HTTP 403). Diese
// Datei prueft die Rolle nicht vorher, das AiSwitchPanel wird serverseitig nur
// fuer admin gerendert (app/(trainer)/planung/page.tsx). Gleiches Fehlermuster
// wie lib/medical/moduleFlagActions.ts: kein stiller Fallback.

import { revalidatePath } from "next/cache";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { JEV_SQUAD_CHECK_FLAG } from "./types";

export type SetJevFlagResult = { ok: true; enabled: boolean } | { ok: false; message: string };

export async function setJevSquadCheckFlag(enabled: boolean): Promise<SetJevFlagResult> {
  const supabase = createSupabaseServerClient();
  const { data, error, status } = await supabase.rpc("rpc_set_module_flag", {
    p_flag: JEV_SQUAD_CHECK_FLAG,
    p_enabled: enabled,
  });

  if (error) {
    const classified = classifyRpcError(error, status);
    return { ok: false, message: classified.message };
  }

  revalidatePath("/planung");
  const row = data as { enabled?: unknown } | null;
  return { ok: true, enabled: typeof row?.enabled === "boolean" ? row.enabled : enabled };
}
