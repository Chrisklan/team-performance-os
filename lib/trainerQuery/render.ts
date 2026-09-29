// Team Performance OS — feste deutsche Vorlagen der Trainer-Query-Antwort
// (AP-70b, ADR-019 §5.1). Rein, ohne Next/Supabase-Importe. KEIN Freitext vom
// Modell: jede Zeile ist eine feste Vorlage, nur mit den server-seitig
// ausgewerteten (evaluate.ts) Werten befuellt. Jede Antwort traegt das Label
// "KI-Antwort" (ADR-019 §5.1, woertlich uebernommen).

import type { TrainerQueryEvaluation, TrainerQueryOutputPlayer } from "./evaluate";
import type { UnsupportedReasonChoice } from "./schema";

export const TRAINER_QUERY_LABEL = "KI-Antwort";

const UNSUPPORTED_REASON_TEXT: Record<UnsupportedReasonChoice, string> = {
  history: "Zeitraeume und Verlaeufe beantwortet diese Funktion nicht.",
  why_explain: "Begruendungen beantwortet diese Funktion nicht.",
  prediction: "Vorhersagen beantwortet diese Funktion nicht.",
  medical_detail: "Medizinische Einzelheiten beantwortet diese Funktion nicht.",
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
