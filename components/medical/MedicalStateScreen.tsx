// Team Performance OS — Zustaende der Medizinsicht ohne Daten.
// Jeder Fall hat einen eigenen Text und eine eigene Handlung, keine Ersatzdaten
// (SESSION-BRIDGE Regel 2). Keine Striche in der Copy.

import Link from "next/link";
import { SignOutButton } from "@/components/trainer/SignOutButton";
import type { KaderErrorCode } from "@/lib/trainer/errors";

export type MedicalStateKind = KaderErrorCode | "PERSON_FORBIDDEN" | "PERSON_NOT_FOUND";

const COPY: Record<MedicalStateKind, { title: string; body: string }> = {
  UNAUTHENTICATED: {
    title: "Anmeldung abgelaufen",
    body: "Deine Anmeldung ist nicht mehr gültig. Melde dich neu an, um die Medizinsicht zu öffnen.",
  },
  FORBIDDEN: {
    title: "Kein Zugriff",
    body: "Die Medizinsicht steht nur Physio und Ärztin oder Arzt zur Verfügung. Mit diesem Konto ist sie nicht sichtbar.",
  },
  NOT_FOUND: {
    title: "Nicht gefunden",
    body: "Die angefragten Daten gibt es nicht. Das ist kein Serverfehler.",
  },
  NETWORK: {
    title: "Server nicht erreichbar",
    body: "Es besteht keine Verbindung zum Server. Prüfe deine Verbindung und lade die Seite erneut.",
  },
  RPC_FAILED: {
    title: "Laden fehlgeschlagen",
    body: "Der Server hat die Anfrage nicht beantwortet. Es werden bewusst keine Ersatzdaten angezeigt. Lade die Seite erneut. Bleibt der Fehler, gib den Fehlercode weiter.",
  },
  MODULE_DISABLED: {
    title: "Noch nicht freigeschaltet",
    body: "LoadDeviation ist für dieses Team noch nicht freigeschaltet. Das entscheidet ausschließlich die Ärztin oder der Arzt.",
  },
  PERSON_FORBIDDEN: {
    title: "Diese Person ist nicht freigegeben",
    body: "Sie ist keine aktive Spielerin deines Teams. Der Versuch steht im Zugriffsprotokoll. Wähle eine Spielerin aus der Kaderliste.",
  },
  PERSON_NOT_FOUND: {
    title: "Spielerin nicht gefunden",
    body: "Unter dieser Adresse gibt es keine Spielerin. Wähle eine Spielerin aus der Kaderliste.",
  },
};

type MedicalStateScreenProps = {
  kind: MedicalStateKind;
  detail?: string;
  /** Innerhalb des Rahmens (Kaderliste sichtbar) statt als ganze Seite. */
  inline?: boolean;
};

const PRIMARY =
  "flex h-12 items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-field";

export function MedicalStateScreen({ kind, detail, inline = false }: MedicalStateScreenProps) {
  const { title, body } = COPY[kind];
  const content = (
    <>
      <div role="alert" className="flex flex-col gap-4">
        <h1 className="font-display text-xl font-bold uppercase leading-tight text-ink">{title}</h1>
        <p className="max-w-xl text-base leading-relaxed text-muted">{body}</p>
        {detail ? <p className="text-sm text-muted">Fehlercode {detail}</p> : null}
      </div>
      <div className="flex flex-wrap items-center gap-3">
        {kind === "UNAUTHENTICATED" ? (
          <Link href="/login?next=/medizin" className={PRIMARY}>
            Zur Anmeldung
          </Link>
        ) : null}
        {kind === "FORBIDDEN" ? (
          <SignOutButton label="Mit anderem Konto anmelden" variant="primary" />
        ) : null}
        {kind === "PERSON_FORBIDDEN" || kind === "PERSON_NOT_FOUND" ? (
          <Link href="/medizin" prefetch={false} className={PRIMARY}>
            Zur Kaderliste
          </Link>
        ) : null}
        {kind === "NETWORK" || kind === "RPC_FAILED" ? (
          // Voller Seitenabruf, damit der Server neu abfragt.
          <a href="/medizin" className={PRIMARY}>
            Erneut laden
          </a>
        ) : null}
        {inline || kind === "UNAUTHENTICATED" || kind === "FORBIDDEN" ? null : <SignOutButton />}
      </div>
    </>
  );

  if (inline) return <div className="flex flex-col gap-6">{content}</div>;
  return (
    <main className="mx-auto flex min-h-screen max-w-2xl flex-col justify-center gap-6 px-6 py-12">
      {content}
    </main>
  );
}
