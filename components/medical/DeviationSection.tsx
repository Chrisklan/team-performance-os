// Team Performance OS — Abschnitt "Abweichungen" in der Medizinsicht (LoadDeviation,
// Modul 5, Bridge Punkt 57 Teil 3). Erste schreibende Interaktion dieser Seite.
//
// Zeile je Beobachtung: Metrik, Prozent, Zustand (Modul-LoadDeviation.md Abschnitt 6,
// "Verbotene UI-Elemente" — kein Ampelbadge, keine Farbe nach Schweregrad, deshalb
// bleibt jede Zeile in derselben Textfarbe wie der Rest der Seite). Freigeben/
// Verwerfen nur bei state=unreviewed, sonst nur das Ergebnis mit Datum.
//
// MODULE_DISABLED ist kein Fehler: das Modul ist fuer dieses Team noch nicht vom
// Arzt freigeschaltet, dieselbe Ansicht wie jeder andere ruhige Zustand ohne Daten.

import { DeviationReviewButtons } from "@/components/medical/DeviationReviewButtons";
import { DisclaimerBar } from "@/components/medical/DisclaimerBar";
import { MedicalStateScreen } from "@/components/medical/MedicalStateScreen";
import type { KaderAccessError } from "@/lib/trainer/errors";
import { deviationMetricLabel, deviationPercent, deviationStateLabel, longDate } from "@/lib/medical/format";
import type { LoadDeviation } from "@/lib/medical/types";

type DeviationSectionProps = {
  personId: string;
  deviations: LoadDeviation[] | null;
  error: KaderAccessError | null;
};

function stateText(deviation: LoadDeviation): string {
  const label = deviationStateLabel(deviation.state);
  if (deviation.state === "unreviewed" || !deviation.reviewed_at) return label;
  return `${label}, ${longDate(deviation.reviewed_at)}`;
}

export function DeviationSection({ personId, deviations, error }: DeviationSectionProps) {
  return (
    <section aria-labelledby="abweichungen-titel" className="flex flex-col gap-4">
      <h2 id="abweichungen-titel" className="text-xs uppercase tracking-wide text-muted">
        Abweichungen
      </h2>
      <DisclaimerBar />

      {error ? (
        <MedicalStateScreen kind={error.code} detail={error.code === "RPC_FAILED" ? error.detail : undefined} inline />
      ) : deviations && deviations.length > 0 ? (
        <ol className="flex flex-col">
          {deviations.map((deviation) => (
            <li
              key={deviation.id}
              className="flex flex-wrap items-center justify-between gap-4 border-t border-white/10 py-3"
            >
              <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
                <p className="text-base text-ink">{deviationMetricLabel(deviation.metric)}</p>
                <p className="font-display text-lg font-bold text-ink">
                  {deviationPercent(deviation.deviation_pct)}
                </p>
                <p className="text-sm text-muted">{longDate(deviation.detected_on)}</p>
              </div>
              <div className="flex items-center gap-4">
                <p className="text-sm text-muted">{stateText(deviation)}</p>
                {deviation.state === "unreviewed" ? (
                  <DeviationReviewButtons personId={personId} deviationId={deviation.id} />
                ) : null}
              </div>
            </li>
          ))}
        </ol>
      ) : (
        <p className="text-sm leading-relaxed text-muted">Keine Abweichung im Zeitraum.</p>
      )}
    </section>
  );
}
