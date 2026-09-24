// Team Performance OS — Rahmen der Medizinsicht.
//
// Zwei ungleiche Spalten: links die Kaderliste auf panel, schmal und ueber die volle
// Hoehe, rechts die gewaehlte Spielerin auf field mit den Handballfeldlinien aus
// dem Anker. Der Bruch zwischen den Flaechen ist Absicht (Design-Codex 1b, Rasterbruch):
// links waehlen, rechts lesen.
//
// Unter md steht nur eine Spalte. Ohne Auswahl ist das die Liste, mit Auswahl die
// Spielerin samt Weg zurueck zur Liste.

import Link from "next/link";
import { SignOutButton } from "@/components/trainer/SignOutButton";
import { PasswordLink } from "@/components/account/PasswordLink";
import { medicalRoleLabel } from "@/lib/medical/format";
import type { MedicalRole } from "@/lib/medical/role";
import type { TeamMember } from "@/lib/medical/types";
import { RosterList } from "./RosterList";

type MedicalShellProps = {
  role: MedicalRole;
  members: TeamMember[];
  selectedId?: string;
  children: React.ReactNode;
};

function Pitch() {
  return (
    <svg
      className="pointer-events-none absolute inset-0 h-full w-full"
      viewBox="0 0 1280 800"
      preserveAspectRatio="xMidYMid slice"
      aria-hidden="true"
    >
      <g fill="none" stroke="#3E5F86" strokeOpacity=".28" strokeWidth="2">
        <path d="M 1400 800 A 420 420 0 0 0 980 380" />
        <path d="M 1400 800 A 620 620 0 0 0 780 180" strokeDasharray="14 12" />
      </g>
    </svg>
  );
}

export function MedicalShell({ role, members, selectedId, children }: MedicalShellProps) {
  const hasSelection = Boolean(selectedId);

  return (
    <div className="flex min-h-screen flex-col">
      <header className="flex flex-wrap items-center justify-between gap-4 border-b-2 border-signal bg-panel px-6 py-3 md:px-8">
        <div className="flex flex-col">
          <p className="font-display text-base font-bold uppercase tracking-wide text-ink">
            Medizin
          </p>
          <p className="text-xs text-muted">Angemeldet als {medicalRoleLabel(role)}</p>
        </div>
        <div className="flex items-center gap-2">
          <PasswordLink />
          <SignOutButton />
        </div>
      </header>

      <div className="flex flex-1 flex-col md:flex-row">
        <aside
          className={`bg-panel md:block md:w-72 md:shrink-0 md:border-r md:border-white/10 ${
            hasSelection ? "hidden" : "block"
          }`}
        >
          <p className="px-6 pb-2 pt-6 text-xs uppercase tracking-wide text-muted">
            Kader, {members.length} {members.length === 1 ? "Spielerin" : "Spielerinnen"}
          </p>
          <RosterList members={members} selectedId={selectedId} />
        </aside>

        <main
          className={`relative flex-1 overflow-hidden ${hasSelection ? "block" : "hidden md:block"}`}
        >
          <Pitch />
          <div className="relative flex flex-col gap-8 px-6 py-8 md:px-8 md:py-12">
            {hasSelection ? (
              <Link
                href="/medizin"
                prefetch={false}
                className="flex h-12 items-center self-start text-sm text-muted underline underline-offset-4 hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal md:hidden"
              >
                Zur Kaderliste
              </Link>
            ) : null}
            {children}
          </div>
        </main>
      </div>
    </div>
  );
}
