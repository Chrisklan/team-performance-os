// Team Performance OS — Team-Tagesübersicht LoadDeviation (Modul 5, Bridge
// Punkt 77). Redaktionelle Liste statt Kartenraster (Design-Codex Schritt 1b,
// Gegenmittel 2): eine Gruppe je Spielerin mit Abweichungen, keine Container.
// Anzahl je Spielerin ist eine neutrale Zahl (DeviationBadge, Modul-Spec
// Abschnitt 6), kein Ampelsymbol, keine Farbe nach Schweregrad.

import { deviationMetricLabel, deviationPercent, deviationPersistence } from "@/lib/medical/format";
import type { DeviationTeamGroup } from "@/lib/trainer/deviations";

type DeviationsTodayListProps = {
  groups: DeviationTeamGroup[];
};

function countLabel(n: number): string {
  return n === 1 ? "1 Abweichung" : `${n} Abweichungen`;
}

export function DeviationsTodayList({ groups }: DeviationsTodayListProps) {
  if (groups.length === 0) {
    return (
      <p className="text-sm leading-relaxed text-muted">
        Heute keine Abweichungen im Team.
      </p>
    );
  }

  return (
    <ol className="flex flex-col">
      {groups.map((group) => (
        <li key={group.player.id} className="border-t border-white/10 py-6 first:border-t-0 first:pt-0">
          <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p className="text-lg font-bold text-ink">
              #{group.player.jersey} · {group.player.name}
            </p>
            <p className="text-sm text-muted">{countLabel(group.deviations.length)}</p>
          </div>
          <p className="text-sm text-muted">{group.player.position}</p>

          <ul className="mt-4 flex flex-col">
            {group.deviations.map((deviation) => {
              const persistence = deviationPersistence(deviation.days_out_7);
              return (
                <li
                  key={deviation.id}
                  className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-t border-white/5 py-3 first:border-t-0 first:pt-0"
                >
                  <p className="text-base text-ink">{deviationMetricLabel(deviation.metric)}</p>
                  <p className="font-display text-lg font-bold text-ink">
                    {deviationPercent(deviation.deviation_pct)}
                  </p>
                  {persistence ? <p className="text-sm text-muted">{persistence}</p> : null}
                </li>
              );
            })}
          </ul>
        </li>
      ))}
    </ol>
  );
}
