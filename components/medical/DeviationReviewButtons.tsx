"use client";

// Team Performance OS — Freigeben/Verwerfen einer ungesichteten LoadDeviation.
// Beide Entscheidungen sind gleich gewichtet: kein hervorgehobener Signalknopf
// fuer die eine oder andere Richtung (Modul-LoadDeviation.md Regel 3, "keine
// Handlungsvorgabe" gilt auch fuer die Optik, nicht nur den Text).
//
// Ladezustand statt optimistischem Update: die Tuer schreibt eine
// Zugriffsprotokollzeile und kann mit 403/404 ablehnen, das soll sichtbar
// bleiben. Bei Erfolg revalidatePath (Server Action) plus router.refresh(),
// damit diese Zeile beim naechsten Rendern verschwindet.

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { reviewDeviation, type ReviewDeviationDecision } from "@/lib/medical/actions";

// h-12 wie jeder andere Knopf im Projekt (SignOutButton, PasswordLink, PRIMARY in
// MedicalStateScreen) -- zugleich die Mindestgroesse 44x44pt aus dem Design-Codex.
const BUTTON =
  "flex h-12 items-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

const LABEL: Record<ReviewDeviationDecision, string> = {
  release: "Freigeben",
  dismiss: "Verwerfen",
};

const BUSY_LABEL: Record<ReviewDeviationDecision, string> = {
  release: "Wird freigegeben",
  dismiss: "Wird verworfen",
};

export function DeviationReviewButtons({
  personId,
  deviationId,
}: {
  personId: string;
  deviationId: string;
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [busy, setBusy] = useState<ReviewDeviationDecision | null>(null);
  const [error, setError] = useState<string | null>(null);

  function decide(decision: ReviewDeviationDecision) {
    setError(null);
    setBusy(decision);
    startTransition(async () => {
      const result = await reviewDeviation(personId, deviationId, decision);
      setBusy(null);
      if (!result.ok) {
        setError(result.message);
        return;
      }
      router.refresh();
    });
  }

  return (
    <div className="flex flex-col items-end gap-2">
      <div className="flex gap-2">
        {(["release", "dismiss"] as const).map((decision) => (
          <button
            key={decision}
            type="button"
            disabled={isPending}
            onClick={() => decide(decision)}
            className={BUTTON}
          >
            {busy === decision ? BUSY_LABEL[decision] : LABEL[decision]}
          </button>
        ))}
      </div>
      {error ? (
        <p role="alert" className="text-sm text-stop-ink">
          {error}
        </p>
      ) : null}
    </div>
  );
}
