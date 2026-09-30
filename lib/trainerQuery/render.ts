// Team Performance OS — feste deutsche Vorlagen der Trainer-Query-Antwort
// (AP-70b, ADR-019 §5.1). Rein, ohne Next/Supabase-Importe. KEIN Freitext vom
// Modell: jede Zeile ist eine feste Vorlage, nur mit den server-seitig
// ausgewerteten (evaluate.ts) Werten befuellt. Jede Antwort traegt das Label
// "KI-Antwort" (ADR-019 §5.1, woertlich uebernommen).

import type { TrainerQueryEvaluation, TrainerQueryOutputPlayer } from "./evaluate";
import type { UnsupportedReasonChoice } from "./schema";
import type { ResolveResult } from "./resolve";

export const TRAINER_QUERY_LABEL = "KI-Antwort";

const UNSUPPORTED_REASON_TEXT: Record<UnsupportedReasonChoice, string> = {
  history: "Zeitraeume und Verlaeufe beantwortet diese Funktion nicht.",
  why_explain: "Begruendungen beantwortet diese Funktion nicht.",
  future_state: "Vorhersagen beantwortet diese Funktion nicht.",
  detail_out_of_scope: "Medizinische Einzelheiten beantwortet diese Funktion nicht.",
  other: "Diese Frage passt nicht in das feste Frageschema.",
  none: "Diese Frage passt nicht in das feste Frageschema.",
};

function bandText(band: TrainerQueryOutputPlayer["band"]): string {
  if (band === "low") return "niedrig";
  if (band === "moderate") return "mittel";
  if (band === "high") return "hoch";
  return "kein Eintrag";
}

function clearanceText(clearance: TrainerQueryOutputPlayer["medicalClearance"]): string {
  if (clearance === "frei") return "frei";
  if (clearance === "eingeschraenkt") return "eingeschraenkt";
  if (clearance === "gesperrt") return "gesperrt";
  return "unbekannt";
}

function playerLine(p: TrainerQueryOutputPlayer): string {
  return (
    `Nummer ${p.jersey} ${p.name}, Position ${p.position}, ` +
    `Readinessband ${bandText(p.band)}, Freigabe ${clearanceText(p.medicalClearance)}, ` +
    `Checkin ${p.hasCheckIn ? "vorhanden" : "fehlt"}`
  );
}

export type TrainerQueryAnswerView = {
  label: string;
  headline: string;
  lines: string[];
};

export function renderTrainerQueryAnswer(evaluation: TrainerQueryEvaluation): TrainerQueryAnswerView {
  if (evaluation.kind === "unsupported") {
    return {
      label: TRAINER_QUERY_LABEL,
      headline: "Diese Frage kann ich nicht beantworten.",
      lines: [UNSUPPORTED_REASON_TEXT[evaluation.reason]],
    };
  }

  if (evaluation.kind === "count") {
    const headline =
      evaluation.count === 0
        ? "Kein Spieler passt auf diese Frage."
        : evaluation.count === 1
          ? "Ein Spieler passt auf diese Frage."
          : `${evaluation.count} Spieler passen auf diese Frage.`;
    return { label: TRAINER_QUERY_LABEL, headline, lines: [] };
  }

  if (evaluation.players.length === 0) {
    return { label: TRAINER_QUERY_LABEL, headline: "Kein Spieler passt auf diese Frage.", lines: [] };
  }

  const headline =
    evaluation.players.length === 1
      ? "Ein Spieler passt auf diese Frage."
      : `${evaluation.players.length} Spieler passen auf diese Frage.`;
  return {
    label: TRAINER_QUERY_LABEL,
    headline,
    lines: evaluation.players.map(playerLine),
  };
}

export function renderTrainerQueryAnswerText(evaluation: TrainerQueryEvaluation): string {
  const view = renderTrainerQueryAnswer(evaluation);
  return [`${view.label}: ${view.headline}`, ...view.lines].join("\n");
}

// Punkt 105 (Security-Review): resolvePlayerRefs (resolve.ts) unterscheidet
// zwei Absagegruende, ambiguous_name und unresolved_token -- vorher zeigte
// queryActions.ts fuer beide dieselbe Absage (UNSUPPORTED_INPUT_ANSWER,
// "keine Zeitraeume oder Verlaeufe"), deren Text fuer keinen der beiden Faelle
// zutrifft (das war schon vor diesem Punkt sachlich falsch fuer beide;
// UNSUPPORTED_INPUT_ANSWER bleibt dem tatsaechlichen Zeitraum-Fall,
// TIME_MARKER_PATTERN in queryActions.ts, vorbehalten). Beide Texte hier
// bleiben bewusst generisch: die ambiguous_name-Antwort nennt KEINE Namen,
// sonst wuerde die Absage selbst verraten, welche Kadermitglieder kollidieren.
//
// Liegt in render.ts statt in queryActions.ts, weil queryActions.ts eine
// "use server"-Datei ist (Next.js Server Actions verlangen dort ausschliesslich
// async Exporte) und diese reine Zuordnungsfunktion direkt, ohne Mock des
// kompletten Gateway-Pfads, testbar bleiben soll.
const AMBIGUOUS_NAME_ANSWER: TrainerQueryAnswerView = {
  label: TRAINER_QUERY_LABEL,
  headline: "Diese Frage kann ich nicht beantworten.",
  lines: ["Die Frage laesst sich nicht eindeutig einer Person zuordnen."],
};

const UNRESOLVED_TOKEN_ANSWER: TrainerQueryAnswerView = {
  label: TRAINER_QUERY_LABEL,
  headline: "Diese Frage kann ich nicht beantworten.",
  lines: ["Diese Frage enthaelt ein Wort oder Format, das hier nicht unterstuetzt wird."],
};

export function resolveFailureAnswer(reason: Extract<ResolveResult, { ok: false }>["reason"]): TrainerQueryAnswerView {
  return reason === "ambiguous_name" ? AMBIGUOUS_NAME_ANSWER : UNRESOLVED_TOKEN_ANSWER;
}
