// Team Performance OS — Freigabe in der Medizinsicht, nur lesend.
//
// Quelle: public.rpc_get_clearance in der Medizinform (ADR-017 Abschnitt 4.2):
// Status, Belastungshinweis, Gueltigkeit, gesetzt von welcher Rolle, dazu die
// offenen Vorschlaege. set_by und proposed_by sind IDs von Medizinpersonen, die
// nicht in der Kaderliste stehen; angezeigt wird deshalb die Rolle, nicht ein Name.
// Setzen und Vorschlagen gehoeren zu AP-47, hier gibt es keine Schaltflaeche dafuer.

import { clearanceLabel, longDate, medicalRoleLabel } from "@/lib/medical/format";
import type { ClearancePayload } from "@/lib/medical/types";

export function ClearanceBlock({ clearance }: { clearance: ClearancePayload }) {
  const current = clearance.clearance;
  const proposals = clearance.open_proposals ?? [];
  const blocked = current?.status === "blocked";

  return (
    <section aria-labelledby="freigabe-titel" className="flex flex-col gap-3">
      <h2 id="freigabe-titel" className="text-xs uppercase tracking-wide text-muted">
        Freigabe heute
      </h2>
      <div className="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <span
          className={`inline-flex h-8 items-center rounded-sm border px-3 font-display text-sm font-bold uppercase tracking-wide ${
            blocked ? "border-stop text-stop-ink" : "border-muted text-ink"
          }`}
        >
          {current ? clearanceLabel(current.status) : "Freigegeben"}
        </span>
        <span className="text-sm text-muted">
          {current
            ? `seit ${longDate(current.valid_from)}${
                current.valid_to ? `, bis ${longDate(current.valid_to)}` : ""
              }${current.set_by_role ? `, gesetzt von ${medicalRoleLabel(current.set_by_role)}` : ""}`
            : "Keine Freigabezeile, es gilt voll freigegeben."}
        </span>
      </div>
      {current?.load_note ? (
        <p className="max-w-prose text-base leading-relaxed text-ink">{current.load_note}</p>
      ) : null}
      {proposals.length > 0 ? (
        <div className="flex flex-col gap-2 border-l-2 border-muted pl-4">
          <p className="text-sm text-muted">
            {proposals.length === 1 ? "Ein offener Vorschlag" : `${proposals.length} offene Vorschläge`}, noch nicht entschieden
          </p>
          <ul className="flex flex-col gap-2">
            {proposals.map((proposal) => (
              <li key={proposal.id} className="text-sm text-ink">
                <span className="font-bold">{clearanceLabel(proposal.status)}</span>
                <span className="text-muted">
                  {" "}
                  vorgeschlagen am {longDate(proposal.proposed_at)} von{" "}
                  {medicalRoleLabel(proposal.proposed_by_role)}
                </span>
                {proposal.rationale ? (
                  <span className="block max-w-prose text-muted">{proposal.rationale}</span>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}
