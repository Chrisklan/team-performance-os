"use client";

// Team Performance OS — Trainer-Query-Funktion (AP-70b). Formular plus
// Ergebnisliste. Importiert AUSSCHLIESSLICH die Server Action askTrainerQuery
// (lib/trainerQuery/queryActions.ts) -- kein direkter DB-/Gateway-Zugriff hier.
//
// Kein Freitext vom Modell: die Antwort ist immer eine feste Vorlage mit dem
// Label "KI-Antwort" (ADR-019 §5.1), siehe lib/trainerQuery/render.ts.

import { useState, useTransition } from "react";
import { askTrainerQuery } from "@/lib/trainerQuery/queryActions";
import type { TrainerQueryAnswerView } from "@/lib/trainerQuery/render";

const BUTTON =
  "flex h-12 items-center justify-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

const INPUT =
  "h-12 w-full rounded-md border border-muted bg-field px-4 text-sm text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal";

export function TrainerQueryPanel() {
  const [question, setQuestion] = useState("");
  const [answer, setAnswer] = useState<TrainerQueryAnswerView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit(formQuestion: string) {
    setError(null);
    startTransition(async () => {
      const result = await askTrainerQuery(formQuestion);
      if (!result.ok) {
        setError(result.message);
        setAnswer(null);
        return;
      }
      setAnswer(result.answer);
    });
  }

  return (
    <section className="flex flex-col gap-4" aria-busy={pending}>
      <div className="flex flex-col gap-1">
        <p className="text-xs font-bold uppercase tracking-wide text-muted">Frage an den Kader</p>
        <p className="max-w-prose text-sm leading-relaxed text-muted">
          Nur zum heutigen Stand, zum Beispiel Anzahl oder Liste nach Readinessband, Freigabe, Checkin oder Position.
          Verlaeufe und Zeitraeume beantwortet diese Funktion nicht.
        </p>
      </div>

      <form
        className="flex flex-col gap-3 sm:flex-row"
        onSubmit={(event) => {
          event.preventDefault();
          if (!question.trim() || pending) return;
          submit(question.trim());
        }}
      >
        <label className="sr-only" htmlFor="trainer-query-input">
          Frage an den Kader
        </label>
        <input
          id="trainer-query-input"
          name="question"
          type="text"
          maxLength={300}
          className={INPUT}
          placeholder="Zum Beispiel: Wie viele Spieler haben heute noch kein Checkin?"
          value={question}
          onChange={(event) => setQuestion(event.target.value)}
          disabled={pending}
        />
        <button type="submit" className={BUTTON} disabled={pending || !question.trim()}>
          {pending ? "Frage laeuft" : "Fragen"}
        </button>
      </form>

      {error ? (
        <p role="alert" className="text-sm text-stop-ink">
          {error}
        </p>
      ) : null}

      {answer ? (
        <div className="flex flex-col gap-2 border-l-2 border-muted py-1 pl-4" role="status" aria-live="polite">
          <p className="text-xs font-bold uppercase tracking-wide text-muted">{answer.label}</p>
          <p className="text-base text-ink">{answer.headline}</p>
          {answer.lines.length > 0 ? (
            <ul className="flex flex-col gap-1">
              {answer.lines.map((line, i) => (
                <li key={i} className="text-sm text-ink">
                  {line}
                </li>
              ))}
            </ul>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
