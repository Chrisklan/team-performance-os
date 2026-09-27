"use client";

// Team Performance OS — Team-Schalter fuer die KI Zuordnung (AP-69), nur admin.
// Dieselbe Bauform wie components/medical/ModuleFlagPanel.tsx: kartenlose
// Sektion mit linkem Akzent, ein Knopf mit Zustand (role="switch"), kein neues
// Schalter-Widget. Der Text legt offen, was bei "an" das Haus verlaesst und an
// wen (ADR-019 §3.5 Punkt 5, G-05: keine Formulierung wie "KI erkennt").

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { setJevSquadCheckFlag } from "@/lib/planung/aiFlagActions";

const BUTTON =
  "flex h-12 items-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

export function AiSwitchPanel({ initialEnabled }: { initialEnabled: boolean }) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [enabled, setEnabled] = useState(initialEnabled);
  const [error, setError] = useState<string | null>(null);

  function toggle() {
    const next = !enabled;
    setError(null);
    startTransition(async () => {
      const result = await setJevSquadCheckFlag(next);
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
      <p className="text-xs font-bold uppercase tracking-wide text-muted">KI Zuordnung für dieses Team</p>
      <p className="text-sm font-bold text-ink">{enabled ? "Eingeschaltet" : "Ausgeschaltet"}</p>
      <p className="text-sm leading-relaxed text-ink">
        An: Band, Lastvergleich und freigegebene Abweichungen gehen pseudonymisiert an OpenRouter/TypeSafe
        (JEV). Aus: nur Regelprüfung v1.
      </p>
      <p className="text-sm leading-relaxed text-muted">
        Namen, Rückennummern, Positionen, Freigaben und Scorezahlen gehen nie hinaus. Die KI Zuordnung kann nur
        „reduziert“ vorschlagen, nie individuell oder aussetzen.
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
              ? "Wird ausgeschaltet"
              : "Wird eingeschaltet"
            : enabled
              ? "Ausschalten"
              : "Einschalten"}
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
