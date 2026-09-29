"use server";

// Team Performance OS — Server Action der Trainer-Query-Funktion (AP-70b).
//
// askTrainerQuery ist die EINZIGE exportierte Server-Action-Schnittstelle
// dieses Pakets (kein weiterer benannter KI-Weg). Datenfluss (ADR-019, exakt
// wie im Auftrag):
//   1. Eingangspruefung: Laengenlimit, G-01 auf die rohe Frage, Zeitmarker-
//      Absage -- OHNE Modellaufruf bei einem Treffer.
//   2. public.rpc_trainer_morning_ops (Trainer-JWT, dieselbe Tuer wie das
//      Dashboard) -- einzige Datenquelle.
//   3. Namen/Rueckennummern deterministisch zu P-Refs aufgeloest (resolve.ts),
//      VOR dem Modellaufruf.
//   4. runModelCall (lib/ai/gateway/run.ts) mit der Trainer-Query-Spec
//      (spec.ts): das Modell bekommt NUR die pseudonymisierte Frage plus
//      festes Frageschema, KEINE Kaderdaten.
//   5. Deterministische Auswertung gegen den Tuer-Payload (evaluate.ts) plus
//      Pflicht-Ausgangswaechter (assertKeysSubset/assertValueProvenance in
//      spec.ts::guard, PLUS forbiddenKeyHits/g01ViolationsInStringValues auf
//      der rohen Antwort in run.ts).
//   6. Feste deutsche Vorlagen, Label "KI-Antwort" (render.ts).
// Keine Speicherung, kein Gespraechsverlauf, kein Cache von Tuer-Snapshots.

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { classifyRpcError } from "@/lib/trainer/errors";
import { readJevConfig } from "@/lib/ai/jev";
import { g01Violations } from "@/lib/ai/guardrails";
import { runModelCall } from "@/lib/ai/gateway/run";
import { buildTrainerQuerySpec } from "./spec";
import { resolvePlayerRefs } from "./resolve";
import { renderTrainerQueryAnswer, type TrainerQueryAnswerView } from "./render";
import type { CoachKaderPayload } from "@/lib/trainer/types";
import { createHash } from "node:crypto";

// Das Modell, das app._mg_purpose_config('ap70_trainer_query') fest vorgibt
// (backend/48_trainer_query.sql). ADR-019 §3.2: nie ein abweichend
// konfiguriertes Modell still benutzen.
const AP70_PINNED_MODEL = "typesafe/jev-1.13";

const MAX_QUESTION_LENGTH = 300;

// I5 (ADR-019): Verlaufsfragen jeder Art sind out of scope. Deutsche und
// englische Zeitmarker, die auf einen Vergangenheits-/Zukunftsbezug ausserhalb
// von "heute" hindeuten -- Absage OHNE Modellaufruf.
const TIME_MARKER_PATTERN =
  /\b(gestern|vorgestern|letzte[nrs]?\s+(woche|monat|tage?)|seit\s+wann|verlauf|historie|bisher|die\s+letzten\s+\d+|vorwoche|woche\s+zuvor|naechste[nrs]?\s+(woche|monat)|morgen|yesterday|last\s+(week|month|days?)|history|trend)\b/i;

export type TrainerQueryResult =
  | { ok: true; answer: TrainerQueryAnswerView }
  | { ok: false; message: string };

function isDenial(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as Record<string, unknown>).code === "42501"
  );
}

function hashInput(question: string, refs: readonly string[]): string {
  return createHash("sha256").update(JSON.stringify({ question, refs })).digest("hex");
}

const UNAVAILABLE_ANSWER: TrainerQueryAnswerView = {
  label: "KI-Antwort",
  headline: "Die KI Antwort ist gerade nicht verfuegbar.",
  lines: [],
};

const UNSUPPORTED_INPUT_ANSWER: TrainerQueryAnswerView = {
  label: "KI-Antwort",
  headline: "Diese Frage kann ich nicht beantworten.",
  lines: ["Bitte nur nach dem heutigen Stand fragen, keine Zeitraeume oder Verlaeufe."],
};

export async function askTrainerQuery(question: string): Promise<TrainerQueryResult> {
  if (typeof question !== "string" || question.trim().length === 0) {
    return { ok: false, message: "Bitte eine Frage eingeben." };
  }
  const trimmed = question.trim();
  if (trimmed.length > MAX_QUESTION_LENGTH) {
    return { ok: false, message: `Frage ist zu lang (maximal ${MAX_QUESTION_LENGTH} Zeichen).` };
  }
  if (g01Violations(trimmed).length > 0) {
    return { ok: false, message: "Diese Frage laesst sich hier nicht stellen." };
  }
  if (TIME_MARKER_PATTERN.test(trimmed)) {
    return { ok: true, answer: UNSUPPORTED_INPUT_ANSWER };
  }

  const supabase = createSupabaseServerClient();
  const { data, error, status } = await supabase.rpc("rpc_trainer_morning_ops");
  if (error) {
    return { ok: false, message: classifyRpcError(error, status).message };
  }
  if (!data || isDenial(data)) {
    return { ok: false, message: "Kein Zugriff auf den Kader." };
  }
  const payload = data as CoachKaderPayload;

  const { pseudonymizedQuestion, refs, mentionedRefs } = resolvePlayerRefs(trimmed, payload);

  const config = readJevConfig();
  const subjectIds = mentionedRefs.map((r) => r.personId);
  const inputHash = hashInput(pseudonymizedQuestion, refs.map((r) => r.ref));

  const spec = buildTrainerQuerySpec({
    ctx: { pseudonymizedQuestion, refs, positions: [] },
    openArgs: { p_input_hash: inputHash, p_subject_ids: subjectIds },
    apiKey: config.provider === "openrouter" ? config.apiKey : null,
    model: config.model ?? AP70_PINNED_MODEL,
    timeoutMs: config.timeoutMs,
    minConfidence: config.minConfidence,
  });

  const result = await runModelCall(spec);

  if (result.status === "off" || result.status === "fallback" || result.status === "rejected") {
    return { ok: true, answer: UNAVAILABLE_ANSWER };
  }
  if (result.status === "empty") {
    return { ok: true, answer: UNSUPPORTED_INPUT_ANSWER };
  }

  return { ok: true, answer: renderTrainerQueryAnswer(result.output) };
}
