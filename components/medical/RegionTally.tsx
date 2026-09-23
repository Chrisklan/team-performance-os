// Team Performance OS — Meldungen je Region, 28 Tage (Signature Element der Medizinsicht).
//
// Der Meldestrich: je Region eine Linie ueber die 28 Tage, dieselbe Normlinie wie
// die Kaderleiste (docs/design/README.md). An jedem Tag mit Meldung steht ein
// Plaettchen auf der Linie. Tage ohne Check-in sind als Luecke gezeichnet (die
// Linie ist dort gestrichelt), damit "nicht gemeldet" und "nicht gefragt" nicht
// verwechselt werden.
//
// Regeln aus Modul Body-Map 7.3 und 8, hier bewusst eingehalten:
//  * Katalogreihenfolge der Tuer, keine eigene Sortierung nach Wert
//  * jede Region in einer eigenen Zeile, kein Links Rechts Paar nebeneinander
//  * keine Faerbung und keine Hoehe nach Schmerz: alle Plaettchen gleich
//  * answeredDays als "an 4 von 21 Tagen", nie als Prozent
//  * Benennung rein zaehlend
// Die hoechste Angabe steht als Zahl daneben, so wie die Tuer sie liefert.

import { countPhrase, dayAxis, reportedDaysByRegion } from "@/lib/medical/bodymap";
import { longDate, shortDate, valueOrDot } from "@/lib/medical/format";
import type { CheckinDay, RegionReportsPayload } from "@/lib/medical/types";

type RegionTallyProps = {
  report: RegionReportsPayload;
  checkins: CheckinDay[];
};

export function RegionTally({ report, checkins }: RegionTallyProps) {
  const days = dayAxis(report.from, report.to);
  const { answered, byRegion } = reportedDaysByRegion(checkins);
  const regions = report.regions;

  return (
    <section aria-labelledby="regionen-titel" className="flex flex-col gap-6">
      <header className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
        <h2
          id="regionen-titel"
          className="font-display text-lg font-bold uppercase tracking-wide text-ink"
        >
          Meldungen je Region, {report.days} Tage
        </h2>
        <p className="text-sm text-muted">
          Check-in {countPhrase(report.answeredDays, report.days)} ·{" "}
          {longDate(report.from)} bis {longDate(report.to)}
        </p>
      </header>

      {regions.length === 0 ? (
        <div className="border-t-2 border-muted/40 py-6">
          <p className="text-base text-ink">Keine Meldung in diesem Zeitraum.</p>
          <p className="mt-2 max-w-prose text-sm leading-relaxed text-muted">
            {report.answeredDays === 0
              ? "In diesen Tagen gab es keinen Check-in. Ohne Check-in gibt es auch keine Meldung."
              : `Die Spielerin hat ${countPhrase(report.answeredDays, report.days)} eingecheckt und dabei keine Region markiert.`}
          </p>
        </div>
      ) : (
        <div className="flex flex-col">
          {/* Tagesachse, einmal fuer alle Zeilen. Unter xl steht der Strich in einer
              eigenen Zeile ueber die volle Breite, die Achse nennt dann nur Anfang und Ende. */}
          <div aria-hidden="true" className="flex justify-between pb-2 text-xs text-muted xl:hidden">
            <span>{shortDate(report.from)}</span>
            <span>{shortDate(report.to)}</span>
          </div>
          <div
            aria-hidden="true"
            className="hidden grid-cols-[minmax(0,12rem)_minmax(0,1fr)_8rem_6rem] gap-x-6 pb-2 xl:grid"
          >
            <span />
            <div className="flex">
              {days.map((day, index) => (
                <span key={day} className="relative flex-1 text-xs text-muted">
                  {index % 7 === 0 ? (
                    <span className="absolute left-0 top-0 whitespace-nowrap">
                      {shortDate(day)}
                    </span>
                  ) : null}
                  &nbsp;
                </span>
              ))}
            </div>
            <span className="text-xs text-muted">Gemeldet</span>
            <span className="text-xs text-muted">Höchste Angabe</span>
          </div>

          <ol className="flex flex-col">
            {regions.map((region) => {
              const reported = byRegion.get(region.region) ?? new Set<string>();
              const label = region.label || region.region;
              const summary = `${label}: gemeldet ${countPhrase(region.reports, report.answeredDays)} mit Check-in${
                region.lastDate ? `, zuletzt am ${longDate(region.lastDate)}` : ""
              }`;
              return (
                <li
                  key={region.region}
                  className="grid grid-cols-2 items-end gap-x-6 gap-y-3 border-t border-white/10 py-3 sm:grid-cols-[minmax(0,1fr)_auto_auto] xl:grid-cols-[minmax(0,12rem)_minmax(0,1fr)_8rem_6rem]"
                >
                  <p className="col-span-2 text-base text-ink sm:col-span-1">
                    {label}
                    {region.legacy ? (
                      <span className="ml-2 text-xs text-muted">Altschlüssel</span>
                    ) : null}
                  </p>

                  <div role="img" aria-label={summary} className="order-last col-span-2 flex h-6 items-end sm:col-span-3 xl:order-none xl:col-span-1">
                    {days.map((day) => {
                      const hasCheckin = answered.has(day);
                      const isReported = reported.has(day);
                      return (
                        <span
                          key={day}
                          className={`flex h-full flex-1 items-end justify-center border-b-2 ${
                            hasCheckin ? "border-muted" : "border-dotted border-muted/40"
                          }`}
                        >
                          {/* Breite anteilig statt Freihandabstand: aufeinanderfolgende Tage bleiben zwei Plaettchen */}
                          {isReported ? <span className="block h-4 w-3/4 bg-ink" /> : null}
                        </span>
                      );
                    })}
                  </div>

                  <p className="text-sm text-ink">
                    <span className="font-display text-lg font-bold">{region.reports}</span>{" "}
                    <span className="text-muted">
                      von {report.answeredDays} {report.answeredDays === 1 ? "Tag" : "Tagen"}
                    </span>
                    {region.lastDate ? (
                      <span className="block text-xs text-muted">
                        zuletzt {shortDate(region.lastDate)}
                      </span>
                    ) : null}
                  </p>

                  <p className="text-sm text-ink">
                    <span className="block text-xs text-muted xl:hidden">höchste Angabe</span>
                    <span className="font-display text-lg font-bold">
                      {valueOrDot(region.highest)}
                    </span>
                    <span className="text-muted"> von 10</span>
                  </p>
                </li>
              );
            })}
          </ol>

          <p className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-muted">
            <span className="flex items-center gap-2">
              <span aria-hidden="true" className="block h-3 w-2 bg-ink" /> Tag mit Meldung
            </span>
            <span className="flex items-center gap-2">
              <span aria-hidden="true" className="block w-4 border-b-2 border-muted" /> Check-in ohne Meldung
            </span>
            <span className="flex items-center gap-2">
              <span aria-hidden="true" className="block w-4 border-b-2 border-dotted border-muted/40" /> kein Check-in
            </span>
          </p>
        </div>
      )}
    </section>
  );
}
