// Team Performance OS — PlayerCard.
// Read-only Karte: Identität, Bereitschaft als Zustandsklasse, Baseline-Trend,
// Medical-Badge (nur Badge) und Heute-Teilnahme. Öffnet den DetailDrawer.
//
// Der Readiness-Zahlwert und die fünf Faktorbalken sind am 2026-09-22 entfallen
// (Befund N7): beide sind für coach und athletic_coach in der kanonischen Matrix
// fett mit "-" markiert, und die Datenbank liefert sie seit Migration
// 20260922000033 nicht mehr mit. An ihrer Stelle steht der ReadinessBandMeter.

import {
  attendanceLabel,
  bandLabel,
  isAuffaellig,
  medicalLabel,
  todayEventLabel,
} from "@/lib/trainer/aggregate";
import type { KaderMember, MedicalStatus } from "@/lib/trainer/types";
import { ReadinessBandMeter } from "./ReadinessBandMeter";
import { ReadinessPulsSparkline } from "./ReadinessPulsSparkline";

const MEDICAL_ICON: Record<MedicalStatus, string> = {
  green: "🟢",
  yellow: "🟡",
  orange: "🟠",
  red: "🔴",
};

type PlayerCardProps = {
  member: KaderMember;
  onSelect: (member: KaderMember) => void;
};

export function PlayerCard({ member, onSelect }: PlayerCardProps) {
  const { player, readiness, baseline, medicalStatus, attendance, todayEvent } =
    member;
  const auffaellig = isAuffaellig(member);

  return (
    <button
      type="button"
      onClick={() => onSelect(member)}
      className={`flex w-full flex-col gap-4 rounded-lg border bg-panel p-6 text-left transition-colors hover:border-signal/40 focus:outline-none focus-visible:ring-2 focus-visible:ring-signal ${
        auffaellig ? "border-stop/60" : "border-white/5"
      }`}
      aria-label={`${player.name}, Rückennummer ${player.jersey}, ${
        player.position
      }. ${
        readiness.band
          ? `Bereitschaft ${bandLabel(readiness.band)}`
          : "Kein Check-in"
      }. Medical-Status ${medicalLabel(medicalStatus)}. Details öffnen.`}
    >
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm text-muted">
            #{player.jersey} · {player.position}
          </p>
          <p className="text-lg font-bold text-ink">{player.name}</p>
        </div>
        <span aria-hidden="true" className="text-lg leading-none">
          {MEDICAL_ICON[medicalStatus]}
        </span>
      </div>

      <div className="flex items-end justify-between gap-4">
        <ReadinessBandMeter band={readiness.band} />
        <ReadinessPulsSparkline
          series={baseline.series}
          rollingAvg={baseline.rollingAvg}
          ariaLabel={`Baseline-Trend für ${player.name}`}
        />
      </div>

      <p className="text-sm text-muted">
        {attendanceLabel(attendance)} · {todayEventLabel(todayEvent)}
      </p>
    </button>
  );
}
