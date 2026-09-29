// Team Performance OS — deterministische Auswertung der Trainer-Query (AP-70b).
// Rein, ohne Next/Supabase-Importe. Das Modell liefert NUR eine strukturierte,
// geschlossene Interpretation der (pseudonymisierten) Frage (Achsen aus
// schema.ts) -- KEINE Kaderdaten. Diese Datei wertet die Interpretation
// deterministisch gegen den Tuer-Payload (die per resolve.ts aufgebauten
// ResolvedPlayerRef-Eintraege) aus, auf dem Server, ohne weiteren Modellaufruf.

import type { ResolvedPlayerRef } from "./resolve";
import {
  BAND_CHOICES,
  CHECKIN_CHOICES,
  CLEARANCE_CHOICES,
  INTENT_CHOICES,
  UNSUPPORTED_REASON_CHOICES,
  type BandChoice,
  type CheckinChoice,
  type ClearanceChoice,
  type IntentChoice,
  type UnsupportedReasonChoice,
} from "./schema";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validChoice<T extends string>(
  answer: unknown,
  allowed: readonly T[],
): { choice: T; confidence: number } | null {
  if (!isRecord(answer)) return null;
  const { choice, confidence } = answer;
  if (typeof choice !== "string" || !(allowed as readonly string[]).includes(choice)) return null;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) return null;
  if (confidence < 0 || confidence > 1) return null;
  return { choice: choice as T, confidence };
}

export type ParsedTrainerQueryAnswers = {
  intent: IntentChoice;
  band: BandChoice;
  clearance: ClearanceChoice;
  checkin: CheckinChoice;
  position: string;
  playerRef: string;
  unsupportedReason: UnsupportedReasonChoice;
};

export type TrainerQueryResultClass = "ok" | "partial" | "invalid";

// Parst die sieben Achsen aus der rohen Modellantwort. intent ist PFLICHT
// (ohne gueltiges intent >= minConfidence ist die gesamte Antwort invalid,
// wie validateJevAnswers()). Jede andere Achse faellt bei einem fehlenden/
// ungueltigen Wert auf einen sicheren neutralen Wert zurueck (any/keine/none)
// -- das schraenkt die Auswertung nie unbeabsichtigt aus, es macht sie nur
// weniger spezifisch (resultClass "partial" statt "invalid").
export function parseTrainerQueryAnswers(
  response: unknown,
  refs: readonly string[],
  positions: readonly string[],
  minConfidence: number,
): { resultClass: TrainerQueryResultClass; parsed: ParsedTrainerQueryAnswers } {
  const fallback: ParsedTrainerQueryAnswers = {
    intent: "unsupported",
    band: "any",
    clearance: "any",
    checkin: "any",
    position: "any",
    playerRef: "keine",
    unsupportedReason: "other",
  };

  const answers = isRecord(response) && isRecord(response.answers) ? response.answers : null;
  if (!answers || !Number.isFinite(minConfidence)) {
    return { resultClass: "invalid", parsed: fallback };
  }

  const intentAnswer = validChoice(answers.intent, INTENT_CHOICES);
  if (!intentAnswer || intentAnswer.confidence < minConfidence) {
    return { resultClass: "invalid", parsed: fallback };
  }

  let degraded = false;

  const bandAnswer = validChoice(answers.band, BAND_CHOICES);
  const band = bandAnswer && bandAnswer.confidence >= minConfidence ? bandAnswer.choice : ((degraded = true), "any" as const);

  const clearanceAnswer = validChoice(answers.clearance, CLEARANCE_CHOICES);
  const clearance =
    clearanceAnswer && clearanceAnswer.confidence >= minConfidence ? clearanceAnswer.choice : ((degraded = true), "any" as const);

  const checkinAnswer = validChoice(answers.checkin, CHECKIN_CHOICES);
  const checkin =
    checkinAnswer && checkinAnswer.confidence >= minConfidence ? checkinAnswer.choice : ((degraded = true), "any" as const);

  const positionChoices = ["any", ...positions] as const;
  const positionAnswer = validChoice(answers.position, positionChoices);
  const position =
    positionAnswer && positionAnswer.confidence >= minConfidence ? positionAnswer.choice : ((degraded = true), "any");

  const refChoices = ["keine", ...refs] as const;
  const playerRefAnswer = validChoice(answers.player_ref, refChoices);
  const playerRef =
    playerRefAnswer && playerRefAnswer.confidence >= minConfidence ? playerRefAnswer.choice : ((degraded = true), "keine");

  const unsupportedReasonAnswer = validChoice(answers.unsupported_reason, UNSUPPORTED_REASON_CHOICES);
  const unsupportedReason =
    unsupportedReasonAnswer && unsupportedReasonAnswer.confidence >= minConfidence
      ? unsupportedReasonAnswer.choice
      : ((degraded = true), intentAnswer.choice === "unsupported" ? ("other" as const) : ("none" as const));

  return {
    resultClass: degraded ? "partial" : "ok",
    parsed: {
      intent: intentAnswer.choice,
      band,
      clearance,
      checkin,
      position,
      playerRef,
      unsupportedReason,
    },
  };
}

// Kontext, den spec.ts fuer buildRequest/parse/guard schliesst (Ctx im Sinne
// von lib/ai/gateway/run.ts::ModelCallSpec). Rein, kein Next/Supabase-Bezug.
export type TrainerQueryContext = {
  pseudonymizedQuestion: string;
  refs: ResolvedPlayerRef[];
  positions: string[];
};

export type TrainerQueryOutputPlayer = {
  ref: string;
  name: string;
  jersey: number;
  position: string;
  band: ResolvedPlayerRef["band"];
  medicalClearance: ResolvedPlayerRef["medicalClearance"];
  hasCheckIn: boolean;
};

export type TrainerQueryEvaluation =
  | { kind: "unsupported"; reason: UnsupportedReasonChoice }
  | { kind: "count"; count: number; matched: TrainerQueryOutputPlayer[] }
  | { kind: "list"; players: TrainerQueryOutputPlayer[] };

function toOutputPlayer(r: ResolvedPlayerRef): TrainerQueryOutputPlayer {
  // Nur Allowlist-Felder (schema.ts::TRAINER_QUERY_OUTPUT_ALLOWLIST) plus ref
  // (der idKey fuer die Herkunfts-Bindung, siehe assertValueProvenance). Jeder
  // Wert kommt 1:1 aus dem Tuer-Payload (ResolvedPlayerRef), nie erfunden.
  return {
    ref: r.ref,
    name: r.name,
    jersey: r.jersey,
    position: r.position,
    band: r.band,
    medicalClearance: r.medicalClearance,
    hasCheckIn: r.hasCheckIn,
  };
}

// Rein deterministisch, kein Modellaufruf. parsed kommt aus
// parseTrainerQueryAnswers, refs sind ALLE aktiven Spieler:innen des Teams
// (resolve.ts::buildPlayerRefs), nicht nur die in der Frage genannten.
export function evaluateTrainerQuery(
  parsed: ParsedTrainerQueryAnswers,
  refs: readonly ResolvedPlayerRef[],
): TrainerQueryEvaluation {
  if (parsed.intent === "unsupported") {
    return { kind: "unsupported", reason: parsed.unsupportedReason };
  }

  let pool = refs;
  if (parsed.playerRef !== "keine") {
    pool = pool.filter((r) => r.ref === parsed.playerRef);
  }
  if (parsed.band !== "any") {
    pool = pool.filter((r) => r.band === parsed.band);
  }
  if (parsed.clearance !== "any") {
    pool = pool.filter((r) => r.medicalClearance === parsed.clearance);
  }
  if (parsed.checkin !== "any") {
    const wantsCheckin = parsed.checkin === "yes";
    pool = pool.filter((r) => r.hasCheckIn === wantsCheckin);
  }
  if (parsed.position !== "any") {
    pool = pool.filter((r) => r.position === parsed.position);
  }

  const players = pool.map(toOutputPlayer);

  if (parsed.intent === "count") {
    return { kind: "count", count: players.length, matched: players };
  }
  return { kind: "list", players };
}
