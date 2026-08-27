// Team Performance OS — PlayerCard.
// Read-only Karte: Identität, Readiness, 5-Faktor-Breakdown, Sparkline,
// Medical-Badge (nur Badge) und Heute-Teilnahme. Öffnet den DetailDrawer.

import {
  FACTOR_ORDER,
  attendanceLabel,
  factorLabels,
  isAuffaellig,
  medicalLabel,
  todayEventLabel,
} from "@/lib/trainer/aggregate";
import type { KaderMember, MedicalStatus } from "@/lib/trainer/types";
import { ReadinessPulsSparkline } from "./ReadinessPulsSparkline";

const MEDICAL_ICON: Record<MedicalStatus, string> = {
  green: "🟢",
  yellow: "🟡",
  orange: "🟠",
  red: "🔴",
};

function factorBarColor(value: number): string {
  if (value < 50) return "bg-warn";
  if (value < 70) return "bg-accent";
  return "bg-ok";
}

type PlayerCardProps = {
  member: KaderMember;
  onSelect: (member: KaderMember) => void;
};

export function PlayerCard({ member, onSelect }: PlayerCardProps) {
  const { player, readiness, baseline, medicalStatus, attendance, todayEvent, hasCheckIn } =
    member;
  const auffaellig = isAuffaellig(member);

  return (
    <button
      type="button"
      onClick={() => onSelect(member)}
      className={`flex w-full flex-col gap-4 rounded-lg border bg-surface-card p-6 text-left transition-colors hover:border-accent/40 focus:outline-none focus-visible:ring-2 focus-visible:ring-accent ${
        auffaellig ? "border-warn/60" : "border-white/5"
      }`}
      aria-label={`${player.name}, Rückennummer ${player.jersey}, ${player.position}. ${
        hasCheckIn ? `Readiness ${readiness.value}` : "Kein Check-in"
      }. Medical-Status ${medicalLabel(medicalStatus)}. Details öffnen.`}
    >
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm text-muted">
            #{player.jersey} · {player.position}
          </p>
          <p className="text-lg font-bold text-ink">{player.name}</p>
        </div>
        <span aria-hidden="true" className="text-xl leading-none">
          {MEDICAL_ICON[medicalStatus]}
        </span>
      </div>

      <div className="flex items-end justify-between gap-4">
        {hasCheckIn ? (
          <p className="text-3xl font-bold text-ink">{readiness.value}</p>
        ) : (
          <div>
            <p className="text-3xl font-bold text-muted">—</p>
            <p className="text-xs text-muted">Kein Check-in</p>
          </div>
        )}
        <ReadinessPulsSparkline
          series={baseline.series}
          rollingAvg={baseline.rollingAvg}
          ariaLabel={`Readiness-Puls Baseline-Trend für ${player.name}`}
        />
      </div>

      <div className="flex flex-col gap-1">
        {FACTOR_ORDER.map((factor) => {
          const value = readiness.factors ? readiness.factors[factor] : null;
          return (
            <div key={factor} className="flex items-center gap-2">
              <span className="w-20 shrink-0 text-xs text-muted">
                {factorLabels[factor]}
              </span>
              <div className="h-1.5 flex-1 rounded-full bg-white/5">
                {value !== null && (
                  <div
                    className={`h-full rounded-full ${factorBarColor(value)}`}
                    style={{ width: `${value}%` }}
                  />
                )}
              </div>
            </div>
          );
        })}
      </div>

      <p className="text-sm text-muted">
        {attendanceLabel(attendance)} · {todayEventLabel(todayEvent)}
      </p>
    </button>
  );
}
