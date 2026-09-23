// Team Performance OS — Kaderliste der Medizinsicht (Auswahl).
//
// Quelle: public.rpc_list_team_members. Name, Position, Freigabestatus, sonst nichts.
// Keine Karten: eine Liste mit Trennlinien, die gewaehlte Spielerin traegt die
// Signalkante links (die einzige signal Flaeche des Screens, sie sagt "hier bist du").
//
// prefetch={false} ist Pflicht und kein Detail: Next laedt Links im Sichtfeld sonst
// vorab. Hier hiesse das, jede Spielerin der Liste wuerde geoeffnet, jede Oeffnung
// schreibt vier Zeilen in ihre Zugriffsuebersicht, ohne dass jemand geklickt hat.

import Link from "next/link";
import { clearanceLabel } from "@/lib/medical/format";
import type { TeamMember } from "@/lib/medical/types";

type RosterListProps = {
  members: TeamMember[];
  selectedId?: string;
};

export function RosterList({ members, selectedId }: RosterListProps) {
  if (members.length === 0) {
    return (
      <div className="flex flex-col gap-2 px-6 py-6">
        <p className="text-base text-ink">Keine Spielerin im Kader.</p>
        <p className="text-sm leading-relaxed text-muted">
          Für dein Team ist noch keine aktive Spielerin angelegt. Sobald es eine gibt, steht sie hier.
        </p>
      </div>
    );
  }

  return (
    <nav aria-label="Kaderliste">
      <ul className="flex flex-col">
        {members.map((member) => {
          const selected = member.id === selectedId;
          const restricted = member.clearance_status !== "full";
          return (
            <li key={member.id} className="border-b border-white/10">
              <Link
                href={`/medizin/${member.id}`}
                prefetch={false}
                aria-current={selected ? "page" : undefined}
                className={`flex min-h-12 flex-col justify-center gap-1 border-l-4 px-6 py-3 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-signal ${
                  selected
                    ? "border-signal bg-field"
                    : "border-transparent hover:bg-field/60"
                }`}
              >
                <span className="text-base text-ink">{member.display_name}</span>
                <span className="flex flex-wrap items-center gap-x-2 text-xs text-muted">
                  {member.person_position ? <span>{member.person_position}</span> : null}
                  {member.person_position ? <span aria-hidden="true">·</span> : null}
                  <span className={restricted ? "text-ink" : undefined}>
                    {clearanceLabel(member.clearance_status)}
                  </span>
                </span>
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
