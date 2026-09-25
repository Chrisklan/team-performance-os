"use client";

// Team Performance OS — Freischalten/Sperren des LoadDeviation Moduls, nur Arzt
// (Modul-LoadDeviation.md Abschnitt 6: "ModuleFlagPanel (nur Arzt)"). Bewusst
// eine kartenlose Sektion im DisclaimerBar-Stil (Design-Codex 1b, Gegenmittel 2)
// statt einer neuen Schalter-Optik: das Projekt kennt bisher keinen Toggle,
// ein Knopf mit Zustand und Ladeanzeige ist dasselbe Bauteil wie
// DeviationReviewButtons und braucht kein neues UI-Kit.
//
// Einzelner Knopf statt zweier (anders als Freigeben/Verwerfen): hier gibt es
// keine zwei gleichwertigen Entscheidungen, sondern einen Zustand, der
// umgeschaltet wird. role="switch"/aria-checked machen das fuer Screenreader
// explizit.

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { setLoadDeviationFlag } from "@/lib/medical/moduleFlagActions";

// Gleiche Klasse wie DeviationReviewButtons/MedicalStateScreen: h-12 ist
// zugleich die Mindestgroesse 44x44pt aus dem Design-Codex.
const BUTTON =
  "flex h-12 items-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

export function ModuleFlagPanel({ initialEnabled }: { initialEnabled: boolean }) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [enabled, setEnabled] = useState(initialEnabled);
  const [error, setError] = useState<string | null>(null);

  function toggle() {
    const next = !enabled;
    setError(null);
    startTransition(async () => {
      const result = await setLoadDeviationFlag(next);
      if (!result.ok) {
        setError(result.message);
        return;
      }
      setEnabled(result.enabled);
      router.refresh();
    });
  }

  return (
    <section className="flex max-w-xl flex-col gap-3 border-l-2 border-muted py-1 pl-4">
      <p className="text-xs font-bold uppercase tracking-wide text-muted">Modul LoadDeviation</p>
      <p className="text-sm leading-relaxed text-ink">
        {enabled
          ? "Freigeschaltet für dieses Team. Das Trainerteam sieht freigegebene Abweichungen, du siehst alle."
          : "Gesperrt für dieses Team. Jede LoadDeviation Ansicht zeigt einen Hinweis statt Daten, auch für dich."}
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <button
          type="button"
          role="switch"
          aria-checked={enabled}
          disabled={isPending}
          onClick={toggle}
          className={BUTTON}
        >
          {isPending
            ? enabled
              ? "Wird gesperrt"
              : "Wird freigeschaltet"
            : enabled
              ? "Sperren"
              : "Freischalten"}
        </button>
        {error ? (
          <p role="alert" className="text-sm text-stop-ink">
            {error}
          </p>
        ) : null}
      </div>
    </section>
  );
}
