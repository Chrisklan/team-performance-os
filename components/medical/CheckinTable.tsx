// Team Performance OS — Check-ins der letzten 28 Tage, nur lesend.
//
// Quelle: public.rpc_medical_checkins. Eine Zeile je Tag, juengster zuerst. Die
// Werte stehen so da, wie die Spielerin sie eingegeben hat: keine Farbe, keine
// Bewertung, keine Ampel (MDR Einordnung, deskriptiv). Der Tippunkt aus body_map
// wird nicht gelesen. Tabelle statt Karten: das ist Nachschlagen, nicht Ueberblick.

import { regionsOfBodyMap } from "@/lib/medical/bodymap";
import { shortDate, sleepHours, valueOrDot } from "@/lib/medical/format";
import type { CheckinDay, RegionReport } from "@/lib/medical/types";

type CheckinTableProps = {
  checkins: CheckinDay[];
  regionLabels: RegionReport[];
};

const COLUMNS = [
  { key: "sleep", label: "Schlaf" },
  { key: "sleep_quality", label: "Schlafqualität" },
  { key: "recovery", label: "Erholung" },
  { key: "energy", label: "Energie" },
  { key: "mental_stress", label: "Stress" },
  { key: "mental_mood", label: "Stimmung" },
  { key: "mental_motivation", label: "Motivation" },
  { key: "training_readiness", label: "Bereitschaft" },
  { key: "pain_max", label: "Schmerz höchster" },
] as const;

function cell(day: CheckinDay, key: (typeof COLUMNS)[number]["key"]): string {
  if (key === "sleep") return sleepHours(day.sleep_duration_min);
  return valueOrDot(day[key]);
}

export function CheckinTable({ checkins, regionLabels }: CheckinTableProps) {
  const labels = new Map(regionLabels.map((r) => [r.region, r.label]));
  const rows = [...checkins].sort((a, b) => b.date.localeCompare(a.date));

  return (
    <section aria-labelledby="checkins-titel" className="flex min-w-0 flex-col gap-4">
      <h2 id="checkins-titel" className="text-xs uppercase tracking-wide text-muted">
        Check-ins im Zeitraum
      </h2>
      {rows.length === 0 ? (
        <p className="text-sm leading-relaxed text-muted">
          Kein Check-in im Zeitraum.
        </p>
      ) : (
        <div className="overflow-x-auto" tabIndex={0} aria-label="Check-ins, seitlich scrollbar">
          <table className="w-full border-collapse text-left text-sm">
            <thead>
              <tr className="border-b-2 border-muted">
                <th scope="col" className="py-2 pl-0 pr-4 font-normal text-muted">Tag</th>
                {COLUMNS.map((column) => (
                  <th key={column.key} scope="col" className="whitespace-nowrap py-2 pl-0 pr-4 font-normal text-muted">
                    {column.label}
                  </th>
                ))}
                <th scope="col" className="py-2 pl-0 pr-4 font-normal text-muted">Regionen</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((day) => {
                const regions = regionsOfBodyMap(day.body_map).map((key) => labels.get(key) ?? key);
                return (
                  <tr key={day.id} className="border-b border-white/10">
                    <th scope="row" className="whitespace-nowrap py-2 pl-0 pr-4 font-normal text-ink">
                      {shortDate(day.date)}
                    </th>
                    {COLUMNS.map((column) => (
                      <td key={column.key} className="whitespace-nowrap py-2 pl-0 pr-4 tabular-nums text-ink">
                        {cell(day, column.key)}
                      </td>
                    ))}
                    <td className="whitespace-nowrap py-2 pl-0 pr-4 text-ink">
                      {regions.length > 0 ? regions.join(", ") : <span className="text-muted">keine</span>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
