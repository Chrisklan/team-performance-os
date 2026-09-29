// Team Performance OS — JEV-Stufe von AP-69, reine Funktionen (ohne Next/Supabase/fetch).
//
// Drei Aufgaben, alle testbar ohne Netz (lib/planung/jevSquadCheck.test.ts):
//   1. buildJevRequest: baut state und questions ausschliesslich aus den
//      Kandidaten der Tuer public.rpc_squad_check_jev_context. Jedes Feld wird
//      einzeln uebernommen (Whitelist), damit ein spaeter hinzugefuegtes Feld
//      der Tuer nie still an das Modell weitergereicht wird.
//   2. validateJevAnswers: harte Pruefung je ref. Ein Hinweis entsteht NUR, wenn
//      der ref zur Kandidatenmenge gehoert, choice exakt "reduced" ist und
//      confidence eine Zahl >= Schwelle ist. Alles andere laesst das Ergebnis
//      der Regel v1 fuer diese Person stehen (ADR-019 §3.2 geschlossene
//      Ausgaben, §3.1 Punkt 5 Rueckfall auf den Menschen).
//   3. mergeOverlays: legt die JEV-Hinweise ueber das Regelergebnis. Nur
//      Personen mit Regel-Vorschlag "volle Gruppe" aus Quelle rule koennen auf
//      "reduziert" wechseln. Ein Freigabe-Spiegel bleibt immer unveraendert, und
//      individuell/aussetzen kommen nie aus JEV (ADR-019 §5.1).
//
// Die Frage an JEV ist eine Choice mit genau drei Optionen: full, reduced,
// unclear. individual und aussetzen existieren als Option nicht. Die Texte
// sind Konstanten und gegen G-01 geprueft (lib/ai/guardrails.test.ts): keine
// Diagnose-, Risiko- oder Verletzungsbegriffe, keine Zahl als Stufe.

import type {
  JevCandidate,
  JevContext,
  JevOverlay,
  ModelCallResultClass,
  SquadAthlete,
} from "./types";
// AP-70a: JevRequest/JevQuestion sind generische Wire-Typen des Gateway-Kerns,
// die Domaene (hier) fuellt sie, importiert sie aber nicht mehr selbst.
import type { JevQuestion, JevRequest } from "@/lib/ai/jevTypes";

export const JEV_CHOICES = ["full", "reduced", "unclear"] as const;
export type JevChoice = (typeof JEV_CHOICES)[number];

export const JEV_FOCUS =
  "Only the listed readiness band, planned load versus own norm and released deviations.";

export function jevQuestionText(ref: string): string {
  return `Should athlete \`athletes[ref=${ref}]\` do this session in the full group or in a reduced-load version?`;
}

export function jevInspectPath(ref: string): string {
  return `athletes[ref=${ref}]`;
}

// Kontrastive Kriterien (jev SKILL.md: what/not_for/examples). Beschreiben nur,
// was im state steht, ohne Bewertung der Person.
export const JEV_CRITERIA: Record<JevChoice, { what: string; not_for: string }> = {
  full: {
    what:
      "The listed readiness band, planned load versus own norm and released deviations are within the athlete's usual range for this session.",
    not_for:
      "A low readiness band together with planned load above own norm, or several released deviations in the last seven days.",
  },
  reduced: {
    what:
      "The listed values depart from the athlete's usual range in a way that fits a lighter version of this session, for example a low readiness band, planned load above own norm or released deviations in the last seven days.",
    not_for: "Values that are all within the usual range, or values that are missing.",
  },
  unclear: {
    what: "The listed values are missing or do not support either the full group or the reduced version.",
    not_for: "Values that clearly fit one of the two options.",
  },
};

// Alle Texte, die an das Modell gehen, fuer den G-01-Test an einer Stelle.
export function jevPromptTexts(sampleRef = "A01"): string[] {
  return [
    jevQuestionText(sampleRef),
    jevInspectPath(sampleRef),
    JEV_FOCUS,
    ...JEV_CHOICES,
    ...Object.values(JEV_CRITERIA).flatMap((c) => [c.what, c.not_for]),
  ];
}

function pickCandidate(c: JevCandidate): JevCandidate {
  return {
    ref: String(c.ref),
    band: c.band,
    planned_load_vs_own_norm: c.planned_load_vs_own_norm,
    released_deviations_7d: Array.isArray(c.released_deviations_7d)
      ? c.released_deviations_7d.map((k) => String(k))
      : [],
  };
}

export function buildJevRequest(ctx: JevContext): JevRequest | null {
  if (!ctx.session || !Array.isArray(ctx.candidates) || ctx.candidates.length === 0) return null;

  const athletes = ctx.candidates.map(pickCandidate);
  const questions: Record<string, JevQuestion> = {};
  for (const a of athletes) {
    questions[a.ref] = {
      type: "choice",
      instructions: {
        question: jevQuestionText(a.ref),
        inspect: jevInspectPath(a.ref),
        focus: JEV_FOCUS,
      },
      criteria: JEV_CRITERIA,
    };
  }

  return {
    state: {
      session: {
        duration_min: ctx.session.duration_min,
        planned_intensity: ctx.session.planned_intensity,
        session_type: ctx.session.session_type,
      },
      athletes,
    },
    questions,
  };
}

export type JevValidation = {
  reducedRefs: string[];
  validCount: number;
  resultClass: Extract<ModelCallResultClass, "ok" | "partial" | "invalid">;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Eine Antwort ist gueltig, wenn sie eine Choice aus der geschlossenen Liste mit
// einer Konfidenz zwischen 0 und 1 ist. Score (score/legend) und Noul (noul) sind
// fuer diese Frage keine gueltige Form.
function validChoice(answer: unknown): { choice: JevChoice; confidence: number } | null {
  if (!isRecord(answer)) return null;
  const { choice, confidence } = answer;
  if (typeof choice !== "string" || !(JEV_CHOICES as readonly string[]).includes(choice)) return null;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) return null;
  if (confidence < 0 || confidence > 1) return null;
  return { choice: choice as JevChoice, confidence };
}

export function validateJevAnswers(
  response: unknown,
  candidateRefs: readonly string[],
  minConfidence: number,
): JevValidation {
  const answers = isRecord(response) && isRecord(response.answers) ? response.answers : null;
  if (!answers || candidateRefs.length === 0 || !Number.isFinite(minConfidence)) {
    return { reducedRefs: [], validCount: 0, resultClass: "invalid" };
  }

  const reducedRefs: string[] = [];
  let validCount = 0;
  for (const ref of candidateRefs) {
    if (!Object.prototype.hasOwnProperty.call(answers, ref)) continue;
    const parsed = validChoice(answers[ref]);
    if (!parsed) continue;
    validCount += 1;
    if (parsed.choice === "reduced" && parsed.confidence >= minConfidence) {
      reducedRefs.push(ref);
    }
  }

  const resultClass =
    validCount === candidateRefs.length ? "ok" : validCount > 0 ? "partial" : "invalid";
  return { reducedRefs, validCount, resultClass };
}

// ref -> person_id nur ueber die refs der Tuer. Ein ref ohne Eintrag erzeugt nichts.
export function overlaysFromRefs(
  reducedRefs: readonly string[],
  refs: JevContext["refs"],
): JevOverlay[] {
  const byRef = new Map<string, string>();
  for (const r of Array.isArray(refs) ? refs : []) {
    if (isRecord(r) && typeof r.ref === "string" && typeof r.person_id === "string") {
      byRef.set(r.ref, r.person_id);
    }
  }
  const out: JevOverlay[] = [];
  const seen = new Set<string>();
  for (const ref of reducedRefs) {
    const personId = byRef.get(ref);
    if (!personId || seen.has(personId)) continue;
    seen.add(personId);
    out.push({ person_id: personId, suggestion: "reduced", hint_key: "j1", source: "jev" });
  }
  return out;
}

export type SquadAthleteView = SquadAthlete & { jev: boolean };

export function mergeOverlays(
  athletes: readonly SquadAthlete[],
  overlays: readonly unknown[],
): SquadAthleteView[] {
  const reducedFor = new Set<string>();
  for (const o of overlays) {
    if (
      isRecord(o) &&
      o.suggestion === "reduced" &&
      o.source === "jev" &&
      o.hint_key === "j1" &&
      typeof o.person_id === "string"
    ) {
      reducedFor.add(o.person_id);
    }
  }

  return athletes.map((a) => {
    const eligible = a.source === "rule" && a.suggestion === "full" && !a.dismissed_hints.includes("j1");
    if (eligible && reducedFor.has(a.person_id)) {
      return { ...a, suggestion: "reduced", jev: true };
    }
    return { ...a, jev: false };
  });
}
