// Team Performance OS — Weg zum eigenen Passwort aus dem Kopf jeder Sicht.
// Ruhig neben "Abmelden": Kontoverwaltung ist keine Hauptaktion des Screens.

import Link from "next/link";

export function PasswordLink() {
  return (
    <Link
      href="/konto/passwort"
      className="flex h-12 items-center justify-center rounded-md px-4 text-sm text-muted transition-colors hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
    >
      Passwort ändern
    </Link>
  );
}
