// Team Performance OS — Frage-Schema und Allowlist der Trainer-Query-Funktion
// (AP-70b). Rein, ohne Next/Supabase-Importe (wie lib/planung/jevSquadCheck.ts).
//
// Das Modell bekommt NIEMALS Kaderdaten, nur die pseudonymisierte Frage
// (resolve.ts hat Namen/Rueckennummern bereits durch P-Refs ersetzt) und
// dieses feste Schema aus geschlossenen JEV-Choice-Fragen. Jede Achse
// (intent/band/clearance/checkin/position/player_ref/unsupported_reason) ist
// eine eigene Choice-Frage -- das Modell interpretiert die Frage NUR, es liest
// nie einen echten Wert. Die tatsaechliche Auswertung (evaluate.ts) laeuft
// danach deterministisch auf dem Server gegen den Tuer-Payload.
//
// ALLOWLIST: Ausgabefelder, die evaluate.ts in die finale Antwort schreiben
// darf (Schluessel-Ebene, siehe lib/ai/gateway/guard.ts::assertKeysSubset --
// die Pruefung ist auf FLACHE Schluesselnamen gemuenzt, nicht auf Pfade).
// Ausdruecklich AUSGESCHLOSSEN (siehe Auftrag): medicalStatus, attendance,
// todayEvent, baseline.
export const TRAINER_QUERY_OUTPUT_ALLOWLIST = [
  "name",
  "jersey",
  "position",
  "band",
  "medicalClearance",
  "hasCheckIn",
] as const;

export const INTENT_CHOICES = ["list", "count", "unsupported"] as const;
export type IntentChoice = (typeof INTENT_CHOICES)[number];

export const BAND_CHOICES = ["low", "moderate", "high", "any"] as const;
export type BandChoice = (typeof BAND_CHOICES)[number];

export const CLEARANCE_CHOICES = ["frei", "eingeschraenkt", "gesperrt", "any"] as const;
export type ClearanceChoice = (typeof CLEARANCE_CHOICES)[number];

export const CHECKIN_CHOICES = ["yes", "no", "any"] as const;
export type CheckinChoice = (typeof CHECKIN_CHOICES)[number];

// Feste Grundliste (Auftrag). "none" = keine Absage, die Frage ist beantwortbar.
export const UNSUPPORTED_REASON_CHOICES = [
  "history",
  "why_explain",
  "prediction",
  "medical_detail",
  "other",
  "none",
] as const;
export type UnsupportedReasonChoice = (typeof UNSUPPORTED_REASON_CHOICES)[number];

export type TrainerQuestionSchemaKey =
  | "intent"
  | "band"
  | "clearance"
  | "checkin"
  | "position"
  | "player_ref"
  | "unsupported_reason";

export const TRAINER_QUERY_SCHEMA_KEYS: readonly TrainerQuestionSchemaKey[] = [
  "intent",
  "band",
  "clearance",
  "checkin",
  "position",
  "player_ref",
  "unsupported_reason",
];

// Kriterien fuer die achsenunabhaengigen (immer gleichen) Fragen. Rein
// strukturell, keine Diagnose-/Risiko-/Verletzungsbegriffe (G-01).
export const INTENT_CRITERIA: Record<IntentChoice, { what: string; not_for: string }> = {
  list: {
    what: "The coach asks which players match one or more of the listed categories (roster listing).",
    not_for: "A question asking only for a total number, or a question this schema cannot answer.",
  },
  count: {
    what: "The coach asks how many players match one or more of the listed categories (a number).",
    not_for: "A question asking for the list of matching players by name, or an unsupported question.",
  },
  unsupported: {
    what:
      "The coach asks something this closed schema cannot answer: a past time range, a request for reasoning, a future state, or a clinical detail beyond the listed categories.",
    not_for: "A plain list or count question about the listed categories for today.",
  },
};

export const BAND_CRITERIA: Record<BandChoice, { what: string; not_for: string }> = {
  low: { what: "The coach's question names the lowest of the three readiness bands.", not_for: "Any other band, or no band mentioned." },
  moderate: { what: "The coach's question names the middle readiness band.", not_for: "Any other band, or no band mentioned." },
  high: { what: "The coach's question names the highest readiness band.", not_for: "Any other band, or no band mentioned." },
  any: { what: "The coach's question does not filter by readiness band at all.", not_for: "A question that names one specific band." },
};

export const CLEARANCE_CRITERIA: Record<ClearanceChoice, { what: string; not_for: string }> = {
  frei: { what: "The coach's question asks about players cleared without restriction.", not_for: "Any other clearance state, or none mentioned." },
  eingeschraenkt: { what: "The coach's question asks about players cleared with restrictions.", not_for: "Any other clearance state, or none mentioned." },
  gesperrt: { what: "The coach's question asks about players who are blocked.", not_for: "Any other clearance state, or none mentioned." },
  any: { what: "The coach's question does not filter by clearance state at all.", not_for: "A question that names one specific clearance state." },
};

export const CHECKIN_CRITERIA: Record<CheckinChoice, { what: string; not_for: string }> = {
  yes: { what: "The coach's question asks about players who already submitted today's check-in.", not_for: "A question about missing check-ins, or no mention of check-in at all." },
  no: { what: "The coach's question asks about players who have NOT submitted today's check-in.", not_for: "A question about completed check-ins, or no mention of check-in at all." },
  any: { what: "The coach's question does not filter by check-in status at all.", not_for: "A question that names a specific check-in status." },
};

export const UNSUPPORTED_REASON_CRITERIA: Record<UnsupportedReasonChoice, { what: string; not_for: string }> = {
  history: { what: "The question asks about a past time range or a trend over time.", not_for: "A plain question about today's state." },
  why_explain: { what: "The question asks for an explanation or reasoning behind a state.", not_for: "A plain filter/list/count question." },
  prediction: { what: "The question asks what will happen next, beyond today's state.", not_for: "A plain question about today's state." },
  medical_detail: { what: "The question asks for a clinical detail beyond the listed categories.", not_for: "A question about the listed categories only." },
  other: { what: "The question does not fit any of the other reasons but still cannot be answered by this closed schema.", not_for: "A question this schema can answer." },
  none: { what: "The question can be answered by this closed schema (list or count over the listed categories).", not_for: "A question that needs one of the other reasons." },
};

export function playerRefCriteria(
  refs: readonly string[],
): Record<string, { what: string; not_for: string }> {
  const out: Record<string, { what: string; not_for: string }> = {
    keine: {
      what: "The coach's question does not name one specific player.",
      not_for: "A question that names exactly one specific player token.",
    },
  };
  for (const ref of refs) {
    out[ref] = {
      what: `The coach's question names the player token \`${ref}\` specifically.`,
      not_for: "Any other player token, or no specific player named.",
    };
  }
  return out;
}

export function positionCriteria(
  positions: readonly string[],
): Record<string, { what: string; not_for: string }> {
  const out: Record<string, { what: string; not_for: string }> = {
    any: {
      what: "The coach's question does not filter by playing position at all.",
      not_for: "A question that names one specific position.",
    },
  };
  for (const p of positions) {
    out[p] = {
      what: `The coach's question names the position \`${p}\` specifically.`,
      not_for: "Any other position, or no position mentioned.",
    };
  }
  return out;
}
