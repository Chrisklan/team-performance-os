// Team Performance OS — ModelCallSpec der Trainer-Query-Funktion (AP-70b). NUR
// serverseitig. Baut die Anfrage aus der bereits pseudonymisierten Frage
// (resolve.ts), ruft dasselbe JEV-Modell wie AP-69 (lib/ai/jev.ts::askJev) und
// wertet die Antwort mit dem Pflicht-Ausgangswaechter (lib/ai/gateway/guard.ts)
// PLUS der eigenen deterministischen Auswertung (evaluate.ts) aus.
//
// Das Modell bekommt NUR state.session.question (die pseudonymisierte Frage)
// und die sieben festen Choice-Fragen aus schema.ts -- state.athletes bleibt
// bewusst ein leeres Array (kein Kaderdatum geht mit, auch nicht ungenutzt als
// Kontext, ADR-019 I1-I7).

import "server-only";
import { askJev } from "@/lib/ai/jev";
import { assertKeysSubset, assertValueProvenance } from "@/lib/ai/gateway/guard";
import type { GatewayOpenPayload, ModelCallSpec } from "@/lib/ai/gateway/run";
import { AP70_TRAINER_QUERY } from "@/lib/ai/gateway/purposes";
import type { JevQuestion, JevRequest } from "@/lib/ai/jevTypes";
import {
  evaluateTrainerQuery,
  parseTrainerQueryAnswers,
  type TrainerQueryContext,
  type TrainerQueryEvaluation,
} from "./evaluate";
import type { ResolvedPlayerRef } from "./resolve";
import {
  BAND_CRITERIA,
  CHECKIN_CRITERIA,
  CLEARANCE_CRITERIA,
  INTENT_CRITERIA,
  TRAINER_QUERY_OUTPUT_ALLOWLIST,
  UNSUPPORTED_REASON_CRITERIA,
  playerRefCriteria,
  positionCriteria,
} from "./schema";

export type { TrainerQueryContext } from "./evaluate";

function distinctPositions(refs: readonly ResolvedPlayerRef[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const r of refs) {
    const p = r.position.trim();
    if (p && !seen.has(p)) {
      seen.add(p);
      out.push(p);
    }
  }
  return out.sort();
}

export function buildTrainerQueryRequest(ctx: TrainerQueryContext): JevRequest | null {
  if (!ctx.pseudonymizedQuestion.trim()) return null;

  const questions: Record<string, JevQuestion> = {
    intent: {
      type: "choice",
      instructions: {
        question: "What does the coach's question ask for?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: INTENT_CRITERIA,
    },
    band: {
      type: "choice",
      instructions: {
        question: "Which readiness band, if any, does the coach's question filter by?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: BAND_CRITERIA,
    },
    clearance: {
      type: "choice",
      instructions: {
        question: "Which medical clearance state, if any, does the coach's question filter by?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: CLEARANCE_CRITERIA,
    },
    checkin: {
      type: "choice",
      instructions: {
        question: "Does the coach's question filter by today's check-in status?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: CHECKIN_CRITERIA,
    },
    position: {
      type: "choice",
      instructions: {
        question: "Which playing position, if any, does the coach's question filter by?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: positionCriteria(ctx.positions),
    },
    player_ref: {
      type: "choice",
      instructions: {
        question: "Does the coach's question name exactly one specific player token?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: playerRefCriteria(ctx.refs.map((r) => r.ref)),
    },
    unsupported_reason: {
      type: "choice",
      instructions: {
        question: "If this closed schema cannot answer the question, why not?",
        inspect: "session.question",
        focus: ctx.pseudonymizedQuestion,
      },
      criteria: UNSUPPORTED_REASON_CRITERIA,
    },
  };

  return {
    state: {
      session: { question: ctx.pseudonymizedQuestion },
      // Bewusst leer: das Modell bekommt keinen einzigen Kaderdatensatz, auch
      // nicht ungenutzt (ADR-019 I1-I7).
      athletes: [],
    },
    questions,
  };
}

export type TrainerQuerySpecInput = {
  ctx: TrainerQueryContext;
  openArgs: { p_input_hash: string; p_subject_ids: string[] };
  apiKey: string | null;
  model: string;
  timeoutMs: number;
  minConfidence: number;
};

// guard() prueft die evaluate()-Ausgabe (NICHT die rohe Modellantwort -- das
// macht run.ts bereits als Pflichtschritt, forbiddenKeyHits/g01Violations) noch
// einmal gegen Allowlist UND Herkunft je Person, bevor sie den Aufrufer
// erreicht. Bei evaluate()-Konstruktion aus ctx.refs kann das praktisch nie
// scheitern (jeder Wert kommt 1:1 aus dem Tuer-Payload), bleibt aber Pflicht.
function guardEvaluation(
  evaluation: TrainerQueryEvaluation,
  ctx: TrainerQueryContext,
): { ok: true; output: TrainerQueryEvaluation } | { ok: false } {
  if (evaluation.kind === "unsupported") return { ok: true, output: evaluation };

  const players = evaluation.kind === "count" ? evaluation.matched : evaluation.players;
  const doorPayload = ctx.refs.map((r) => ({
    ref: r.ref,
    name: r.name,
    jersey: r.jersey,
    position: r.position,
    band: r.band,
    medicalClearance: r.medicalClearance,
    hasCheckIn: r.hasCheckIn,
  }));

  if (!assertKeysSubset(players, doorPayload, TRAINER_QUERY_OUTPUT_ALLOWLIST)) {
    return { ok: false };
  }
  if (!assertValueProvenance(players, doorPayload, "ref")) {
    return { ok: false };
  }

  return { ok: true, output: evaluation };
}

export function buildTrainerQuerySpec(
  input: TrainerQuerySpecInput,
): ModelCallSpec<typeof AP70_TRAINER_QUERY> {
  const positions = distinctPositions(input.ctx.refs);
  const ctx: TrainerQueryContext = { ...input.ctx, positions };
  const fallback: TrainerQueryEvaluation = { kind: "unsupported", reason: "other" };

  return {
    purpose: AP70_TRAINER_QUERY,
    model: input.model,
    emptyOutput: fallback,
    fallbackOutput: fallback,
    apiKey: input.apiKey,
    timeoutMs: input.timeoutMs,
    openArgs: input.openArgs,
    toCtx: (_openPayload: GatewayOpenPayload) => ctx,
    buildRequest: (c) => buildTrainerQueryRequest(c),
    callProvider: (request, opts) => askJev(request, opts),
    parse: (body, c) => {
      const result = parseTrainerQueryAnswers(
        body,
        c.refs.map((r) => r.ref),
        c.positions,
        input.minConfidence,
      );
      return result;
    },
    guard: (parsed, c) => {
      const evaluation = evaluateTrainerQuery(parsed, c.refs);
      return guardEvaluation(evaluation, c);
    },
    onProviderError: (outcome) => {
      if (outcome.kind === "http_error" || outcome.kind === "rate_limited") {
        console.warn(`Trainer query: HTTP ${outcome.status}`);
      }
    },
  };
}
