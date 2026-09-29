"use server";

// Team Performance OS — Server Actions der Pruefung Plan gegen Zustand (AP-69).
//
// Jeder Aufruf laeuft mit dem JWT der angemeldeten Person (createSupabaseServer
// Client, Cookies), nie mit dem Service Role Key (ADR-019 §3.3). Die Tueren pruefen
// Rolle und Team selbst (Muster D), diese Datei entscheidet keine Rechte.
//
// runJevSquadCheck ist die einzige Stelle, an der ein Modell aufgerufen wird.
// Seit AP-70a laeuft der Ablauf ueber lib/ai/gateway/run.ts::runModelCall (der
// gemeinsame Gateway-Kern), diese Funktion baut nur noch die AP-69-spezifische
// ModelCallSpec. Beobachtbares Verhalten unveraendert gegenueber AP-69/Punkt 87
// (siehe lib/planung/squadCheckActions.test.ts, Schritt-0-Charakterisierung):
//   1. Betreiber-Notaus: JEV_ENABLED nicht "true" oder kein Key -> off.
//   2. rpc_squad_check_jev_context (legt die pending-Protokollzeile an, ueber
//      app._mg_open dahinter). Fehler, Ablehnung, 55000 -> fallback. Keine
//      Kandidaten (call_id NULL) -> no_candidates (Gateway-Status "empty").
//      Das Server-Secret (MODEL_GATEWAY_SECRET hat Vorrang, JEV_CONTEXT_SECRET
//      bleibt der Uebergangs-Fallback bis zur Cloud-Umbenennung, siehe
//      lib/ai/gateway/config.ts::readGatewaySwitchConfig -- Korrektur der
//      vorherigen, umgekehrten Aussage hier, Fixrunde L2) reicht
//      lib/ai/gateway/db.ts automatisch durch.
//   3. Request nur aus den Kandidaten, Frage als Konstante (jevSquadCheck.ts).
//   4. fetch mit Timeout, cache no-store, keine Wiederholung, keine Bodies im Log.
//   5. Harte Pruefung je ref, Hinweis nur bei choice "reduced" und Konfidenz ab
//      JEV_MIN_CONFIDENCE.
//   6. Ausgangswaechter (guard): overlaysFromRefs plus Schluesselpruefung --
//      kann fuer AP-69 praktisch nie ablehnen (die Ausgabe besteht nur aus
//      server-generierten Literalen/dem eigenen refs-Mapping), bleibt aber
//      als gemeinsamer Baustein Pflicht (lib/ai/gateway/guard.ts).
//   7. rpc_finish_model_call, Fehler dort ignoriert (Zeile bleibt pending).
//   8. Rueckgabe nur person_id/suggestion/hint_key/source, keine Konfidenz.
//   9. Jeder Fehler -> fallback, nie eine Exception bis zum Trainer.

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { isUuid } from "@/lib/medical/role";
import { askJev, readJevConfig } from "@/lib/ai/jev";
import { assertKeysSubset } from "@/lib/ai/gateway/guard";
import { AP69_SQUAD_CHECK } from "@/lib/ai/gateway/purposes";
import { runModelCall, type GatewayOpenPayload } from "@/lib/ai/gateway/run";
import { buildJevRequest, overlaysFromRefs, validateJevAnswers } from "./jevSquadCheck";
import type { DismissableHintKey, JevContext, JevRunResult, SquadCheckPayload } from "./types";
import { DISMISSABLE_HINT_KEYS } from "./types";

// Das Modell, das app._mg_purpose_config('ap69_squad_check') fest vorgibt
// (backend/47_model_gateway_core.sql). Ein abweichend konfiguriertes
// JEV_MODEL wird nicht still benutzt (ADR-019 §3.2) -- config.model
// ueberschreibt diesen Erwartungswert nur, wenn die Umgebungsvariable gesetzt ist.
const AP69_PINNED_MODEL = "typesafe/jev-1.13";

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

// AP-69-Kandidatenfelder, die guard() als "vom Tuer-Payload selbst
// stammend" akzeptiert -- person_id/suggestion/hint_key/source sind
// server-generierte Literale bzw. das eigene refs-Mapping, nie ein vom
// Modell frei erfundenes Feld. Siehe lib/ai/gateway/guard.ts::assertKeysSubset.
const AP69_OVERLAY_KEY_ALLOWLIST = ["person_id", "suggestion", "hint_key", "source"] as const;

export async function runJevSquadCheck(
  sessionId: string,
  durationMin: number,
  intensity: number,
): Promise<JevRunResult> {
  const config = readJevConfig();
  if (!isUuid(sessionId) || !validDuration(durationMin) || !validIntensity(intensity)) {
    return { status: "fallback", overlays: [] };
  }

  // AP-70a Code-Review P1 (Fixrunde): ModelCallSpec ist jetzt ueber
  // PurposeTypeMap[P] an purpose gebunden (lib/ai/gateway/purposes.ts), die
  // vier Generics werden aus purpose: AP69_SQUAD_CHECK abgeleitet, kein
  // expliziter Typ-Aufruf mehr noetig -- ein falsch verdrahtetes Feld unten
  // ist jetzt ein Typfehler statt klaglos durchzukompilieren.
  const result = await runModelCall({
    purpose: AP69_SQUAD_CHECK,
    model: config.model ?? AP69_PINNED_MODEL,
    emptyOutput: [],
    fallbackOutput: [],
    apiKey: config.provider === "openrouter" ? config.apiKey : null,
    timeoutMs: config.timeoutMs,
    openArgs: {
      p_session_id: sessionId,
      p_duration_min: durationMin,
      p_planned_intensity: intensity,
    },
    toCtx: (openPayload: GatewayOpenPayload) => openPayload as unknown as JevContext,
    buildRequest: (ctx) => buildJevRequest(ctx),
    callProvider: (request, opts) => askJev(request, opts),
    parse: (body, ctx) => {
      const refs = ctx.candidates.map((c) => c.ref);
      const validation = validateJevAnswers(body, refs, config.minConfidence);
      return { resultClass: validation.resultClass, parsed: validation };
    },
    guard: (validation, ctx) => {
      const overlays = overlaysFromRefs(validation.reducedRefs, ctx.refs);
      // Pflicht-Ausgangswaechter (AP-70a): overlays bestehen nur aus
      // person_id (eigenes refs-Mapping) und den drei server-generierten
      // Literalen suggestion/hint_key/source -- assertKeysSubset ist damit
      // fuer AP-69 immer erfuellt, bleibt aber als gemeinsamer Baustein aktiv.
      if (!assertKeysSubset(overlays, ctx.refs, AP69_OVERLAY_KEY_ALLOWLIST)) {
        return { ok: false };
      }
      return { ok: true, output: overlays };
    },
    onProviderError: (outcome) => {
      if (outcome.kind === "http_error" || outcome.kind === "rate_limited") {
        // Nur der Statuscode, nie ein Body (ADR-019 §3.7).
        console.warn(`JEV squad check: HTTP ${outcome.status}`);
      }
    },
  });

  const status: JevRunResult["status"] =
    result.status === "empty" ? "no_candidates" : result.status === "rejected" ? "fallback" : result.status;
  return { status, overlays: result.output };
}
