"use server";

// Team Performance OS — Server Actions der Pruefung Plan gegen Zustand (AP-69).
//
// Jeder Aufruf laeuft mit dem JWT der angemeldeten Person (createSupabaseServer
// Client, Cookies), nie mit dem Service Role Key (ADR-019 §3.3). Die Tueren pruefen
// Rolle und Team selbst (Muster D), diese Datei entscheidet keine Rechte.
//
// runJevSquadCheck ist die einzige Stelle, an der ein Modell aufgerufen wird.
// Ablauf und Rueckfall (mit Chris abgestimmt):
//   1. Betreiber-Notaus: JEV_ENABLED nicht "true" oder kein Key -> off.
//   2. public.rpc_squad_check_jev_context (legt die pending-Protokollzeile an).
//      Fehler, Ablehnung, 55000 -> fallback. Keine Kandidaten -> no_candidates.
//   3. Request nur aus den Kandidaten, Frage als Konstante (jevSquadCheck.ts).
//   4. fetch mit Timeout, cache no-store, keine Wiederholung, keine Bodies im Log.
//   5. Harte Pruefung je ref, Hinweis nur bei choice "reduced" und Konfidenz ab
//      JEV_MIN_CONFIDENCE.
//   6. public.rpc_finish_model_call, Fehler dort ignoriert (Zeile bleibt pending).
//   7. Rueckgabe nur person_id/suggestion/hint_key/source, keine Konfidenz.
//   8. Jeder Fehler in 2 bis 6 -> fallback, nie eine Exception bis zum Trainer.

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { isUuid } from "@/lib/medical/role";
import { askJev, readJevConfig, type JevCallOutcome } from "@/lib/ai/jev";
import { buildJevRequest, overlaysFromRefs, validateJevAnswers } from "./jevSquadCheck";
import type {
  DismissableHintKey,
  JevContext,
  JevRunResult,
  ModelCallResultClass,
  SquadCheckPayload,
} from "./types";
import { DISMISSABLE_HINT_KEYS } from "./types";

type ServerClient = ReturnType<typeof createSupabaseServerClient>;

export type SquadCheckResult = { ok: true; payload: SquadCheckPayload } | { ok: false; message: string };
export type HintActionResult = { ok: true } | { ok: false; message: string };

function validDuration(value: number): boolean {
  return Number.isInteger(value) && value > 0 && value <= 300;
}

function validIntensity(value: number): boolean {
  return Number.isInteger(value) && value >= 1 && value <= 10;
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;

function isDenial(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as Record<string, unknown>).code === "42501"
  );
}

export async function runSquadCheck(input: {
  sessionDate: string;
  durationMin: number;
  intensity: number;
  sessionId: string | null;
}): Promise<SquadCheckResult> {
  if (!DATE.test(input.sessionDate)) return { ok: false, message: "Datum fehlt." };
  if (!validDuration(input.durationMin)) return { ok: false, message: "Dauer zwischen 1 und 300 Minuten angeben." };
  if (!validIntensity(input.intensity)) return { ok: false, message: "Intensität zwischen 1 und 10 angeben." };
  if (input.sessionId !== null && !isUuid(input.sessionId)) return { ok: false, message: "Einheit nicht gefunden." };

  const supabase = createSupabaseServerClient();
  const { data, error, status } = await supabase.rpc("rpc_get_session_squad_check", {
    p_session_date: input.sessionDate,
    p_duration_min: input.durationMin,
    p_planned_intensity: input.intensity,
    p_session_id: input.sessionId,
  });
  if (error) return { ok: false, message: classifyRpcError(error, status).message };
  if (!data || isDenial(data)) return { ok: false, message: "Kein Zugriff auf die Prüfung." };
  return { ok: true, payload: data as SquadCheckPayload };
}

function isDismissableKey(key: string): key is DismissableHintKey {
  return (DISMISSABLE_HINT_KEYS as readonly string[]).includes(key);
}

async function hintCall(
  fn: "rpc_dismiss_session_hint" | "rpc_restore_session_hint",
  sessionId: string,
  personId: string,
  hintKey: string,
): Promise<HintActionResult> {
  if (!isUuid(sessionId) || !isUuid(personId) || !isDismissableKey(hintKey)) {
    return { ok: false, message: "Dieser Hinweis lässt sich nicht wegklicken." };
  }
  const supabase = createSupabaseServerClient();
  const { data, error, status } = await supabase.rpc(fn, {
    p_session_id: sessionId,
    p_person_id: personId,
    p_hint_key: hintKey,
  });
  if (error) {
    if (error.code === "42501") return { ok: false, message: "Dieser Hinweis lässt sich nicht wegklicken." };
    return { ok: false, message: classifyRpcError(error, status).message };
  }
  if (isDenial(data)) return { ok: false, message: "Dieser Hinweis lässt sich nicht wegklicken." };
  return { ok: true };
}

export async function dismissSessionHint(sessionId: string, personId: string, hintKey: string) {
  return hintCall("rpc_dismiss_session_hint", sessionId, personId, hintKey);
}

export async function restoreSessionHint(sessionId: string, personId: string, hintKey: string) {
  return hintCall("rpc_restore_session_hint", sessionId, personId, hintKey);
}

const FALLBACK: JevRunResult = { status: "fallback", overlays: [] };

function resultClassFor(outcome: Exclude<JevCallOutcome, { kind: "ok" }>): ModelCallResultClass {
  return outcome.kind;
}

async function finishCall(
  supabase: ServerClient,
  callId: number,
  resultClass: ModelCallResultClass,
  latencyMs: number | null,
): Promise<void> {
  try {
    await supabase.rpc("rpc_finish_model_call", {
      p_call_id: callId,
      p_result_class: resultClass,
      p_latency_ms: latencyMs === null ? null : Math.max(0, Math.round(latencyMs)),
    });
  } catch {
    // Bewusst ignoriert: die Protokollzeile bleibt pending sichtbar.
  }
}

export async function runJevSquadCheck(
  sessionId: string,
  durationMin: number,
  intensity: number,
): Promise<JevRunResult> {
  const config = readJevConfig();
  if (!config.enabled || config.apiKey === null || config.provider !== "openrouter") {
    return { status: "off", overlays: [] };
  }
  if (!isUuid(sessionId) || !validDuration(durationMin) || !validIntensity(intensity)) {
    return FALLBACK;
  }

  let supabase: ServerClient;
  let ctx: JevContext;
  try {
    supabase = createSupabaseServerClient();
    const { data, error } = await supabase.rpc("rpc_squad_check_jev_context", {
      p_session_id: sessionId,
      p_duration_min: durationMin,
      p_planned_intensity: intensity,
    });
    if (error || !data || isDenial(data)) return FALLBACK;
    ctx = data as JevContext;
  } catch {
    return FALLBACK;
  }

  if (ctx.call_id === null || ctx.call_id === undefined || !Array.isArray(ctx.candidates) || ctx.candidates.length === 0) {
    return { status: "no_candidates", overlays: [] };
  }
  const callId = ctx.call_id;

  try {
    // Das Modell kommt aus der Tuer (dort protokolliert, festgeschrieben). Ein
    // abweichend konfiguriertes JEV_MODEL wird nicht still benutzt.
    const model = typeof ctx.model === "string" ? ctx.model : null;
    if (!model || (config.model !== null && config.model !== model)) {
      await finishCall(supabase, callId, "invalid", null);
      return FALLBACK;
    }

    const request = buildJevRequest(ctx);
    if (!request) {
      await finishCall(supabase, callId, "invalid", null);
      return FALLBACK;
    }

    const outcome = await askJev(request, { model, apiKey: config.apiKey, timeoutMs: config.timeoutMs });
    if (outcome.kind !== "ok") {
      if (outcome.kind === "http_error" || outcome.kind === "rate_limited") {
        // Nur der Statuscode, nie ein Body (ADR-019 §3.7).
        console.warn(`JEV squad check: HTTP ${outcome.status}`);
      }
      await finishCall(supabase, callId, resultClassFor(outcome), outcome.latencyMs);
      return FALLBACK;
    }

    const refs = ctx.candidates.map((c) => c.ref);
    const validation = validateJevAnswers(outcome.body, refs, config.minConfidence);
    await finishCall(supabase, callId, validation.resultClass, outcome.latencyMs);
    if (validation.resultClass === "invalid") return FALLBACK;

    return {
      status: validation.resultClass === "ok" ? "ok" : "partial",
      overlays: overlaysFromRefs(validation.reducedRefs, ctx.refs),
    };
  } catch {
    return FALLBACK;
  }
}
