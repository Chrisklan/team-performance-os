"use client";

// Team Performance OS — Auffangnetz fuer unerwartete Fehler im Trainer-Segment.
// Die erwarteten Faelle (nicht angemeldet, kein Zugriff, Server weg, RPC-Fehler,
// leerer Kader) rendert die Seite selbst, weil Next.js in Produktion Message und
// Felder von Server-Component-Fehlern entfernt. Hier kommt nur der Digest an.

import { useEffect } from "react";
import { KaderStateScreen } from "@/components/trainer/KaderStateScreen";

export default function TrainerError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("Trainer-Segment:", error.digest ?? error.message);
  }, [error]);

  return (
    <KaderStateScreen kind="UNEXPECTED" detail={error.digest} onRetry={reset} />
  );
}
