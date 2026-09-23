// Team Performance OS — Zustaende des Trainer-Dashboards ohne Kader.
// Jeder Fehlerfall hat einen eigenen Text und eine eigene Handlung. Es gibt keine
// Ersatzdaten (SESSION-BRIDGE Regel 2). Alle Texte deskriptiv, ohne Bindestriche.

import Link from "next/link";
import { SignOutButton } from "./SignOutButton";
import type { KaderErrorCode } from "@/lib/trainer/errors";

export type KaderStateKind = KaderErrorCode | "EMPTY" | "UNEXPECTED";

type Copy = {
  title: string;
  body: string;
};

const COPY: Record<KaderStateKind, Copy> = {
  UNAUTHENTICATED: {
    title: "Anmeldung abgelaufen",
    body: "Deine Anmeldung ist nicht mehr gültig. Melde dich neu an, um den Kader zu sehen.",
  },
  FORBIDDEN: {
    title: "Kein Zugriff",
    body: "Mit diesem Konto ist der Kader nicht sichtbar. Er steht nur dem Trainerteam zur Verfügung. Melde dich mit einem Trainerkonto an.",
  },
  NOT_FOUND: {
    title: "Kader nicht gefunden",
    body: "Zu deinem Konto gibt es keinen Kader. Das ist kein Serverfehler. Prüfe, ob du im richtigen Team angemeldet bist.",
  },
  NETWORK: {
    title: "Server nicht erreichbar",
    body: "Der Kader konnte nicht geladen werden, weil keine Verbindung zum Server besteht. Prüfe deine Verbindung und lade die Seite erneut.",
  },
  RPC_FAILED: {
    title: "Kader konnte nicht geladen werden",
    body: "Der Server hat die Anfrage nicht beantwortet. Es werden bewusst keine Ersatzdaten angezeigt. Lade die Seite erneut. Bleibt der Fehler, gib den Fehlercode weiter.",
  },
  EMPTY: {
    title: "Noch kein Kader",
    body: "Für dein Team sind noch keine Personen im Kader hinterlegt. Sobald Personen angelegt sind, erscheinen sie hier.",
  },
  UNEXPECTED: {
    title: "Unerwarteter Fehler",
    body: "Beim Laden ist etwas schiefgelaufen. Es werden bewusst keine Ersatzdaten angezeigt. Lade die Seite erneut. Bleibt der Fehler, gib den Fehlercode weiter.",
  },
};

type KaderStateScreenProps = {
  kind: KaderStateKind;
  /** Technischer Code (z.B. 42501 oder Digest), nur als kleine Referenzzeile. */
  detail?: string;
  /** Ersetzt den Standard "Erneut laden" (z.B. reset() aus error.tsx). */
  onRetry?: () => void;
};

export function KaderStateScreen({ kind, detail, onRetry }: KaderStateScreenProps) {
  const { title, body } = COPY[kind];

  return (
    <main className="mx-auto flex min-h-screen max-w-2xl flex-col justify-center gap-6 px-6 py-12">
      <div
        role={kind === "EMPTY" ? "status" : "alert"}
        className="flex flex-col gap-4"
      >
        <h1 className="text-2xl font-bold leading-tight text-ink">{title}</h1>
        <p className="max-w-xl text-base leading-relaxed text-muted">{body}</p>
        {detail ? (
          <p className="text-sm text-muted">Fehlercode {detail}</p>
        ) : null}
      </div>

      <div className="flex flex-wrap items-center gap-3">
        {kind === "UNAUTHENTICATED" ? (
          <Link
            href="/login?next=/dashboard"
            className="flex h-12 items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-field"
          >
            Zur Anmeldung
          </Link>
        ) : null}

        {kind === "FORBIDDEN" ? (
          <SignOutButton label="Mit anderem Konto anmelden" variant="primary" />
        ) : null}

        {kind === "NETWORK" || kind === "RPC_FAILED" || kind === "UNEXPECTED" || kind === "EMPTY" ? (
          onRetry ? (
            <button
              type="button"
              onClick={onRetry}
              className="flex h-12 items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-field"
            >
              Erneut laden
            </button>
          ) : (
            // Voller Seitenabruf, damit der Server neu abfragt.
            <a
              href="/dashboard"
              className="flex h-12 items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-field"
            >
              Erneut laden
            </a>
          )
        ) : null}

        {kind === "NOT_FOUND" ? (
          <SignOutButton label="Mit anderem Konto anmelden" variant="primary" />
        ) : null}

        {kind !== "UNAUTHENTICATED" && kind !== "FORBIDDEN" && kind !== "NOT_FOUND" ? <SignOutButton /> : null}
      </div>
    </main>
  );
}
