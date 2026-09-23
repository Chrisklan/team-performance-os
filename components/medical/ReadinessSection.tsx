// Team Performance OS — Readiness in der Medizinsicht, nur lesend.
//
// Quelle: public.rpc_medical_readiness. Medizin bekommt score_total und factors
// (Modul 7 Abschnitt 5), das Trainerteam nur das Band. Gezeigt wird der juengste
// Tag im Zeitraum: Band wie im Trainer-Dashboard (dieselbe Form, damit beide
// Sichten dieselbe Sprache sprechen), dazu Zahl und Faktoren. Keine Kurve, keine
// Ableitung, keine Bewertung.

import { ReadinessBandMeter } from "@/components/trainer/ReadinessBandMeter";
import { factorLabel, longDate } from "@/lib/medical/format";
import type { ReadinessPayload } from "@/lib/medical/types";

export function ReadinessSection({ readiness }: { readiness: ReadinessPayload }) {
  const latest = readiness.scores.at(-1) ?? null;
  const factors = latest?.factors ? Object.entries(latest.factors) : [];

  return (
    <section aria-labelledby="readiness-titel" className="flex flex-col gap-4">
      <h2 id="readiness-titel" className="text-xs uppercase tracking-wide text-muted">
        Readiness, jüngster Tag
      </h2>
      {latest ? (
        <div className="flex flex-wrap items-end gap-x-12 gap-y-6">
          <div className="flex items-end gap-6">
            <ReadinessBandMeter band={latest.band} variant="large" />
            {latest.score_total !== null ? (
              <p className="font-display text-3xl font-bold leading-none text-ink">
                {Math.round(latest.score_total)}
              </p>
            ) : null}
          </div>
          <p className="text-sm text-muted md:self-end">
            vom {longDate(latest.date)}, {readiness.scores.length}{" "}
            {readiness.scores.length === 1 ? "Wert" : "Werte"} im Zeitraum
          </p>
          {factors.length > 0 ? (
            <dl className="grid grid-cols-[auto_auto] justify-start gap-x-6 gap-y-1 text-sm sm:grid-flow-col sm:grid-cols-none sm:grid-rows-2">
              {factors.map(([key, value]) => (
                <div key={key} className="contents">
                  <dt className="text-muted">{factorLabel(key)}</dt>
                  <dd className="text-ink">
                    {typeof value === "number" ? value.toFixed(2).replace(".", ",") : String(value)}
                  </dd>
                </div>
              ))}
            </dl>
          ) : null}
        </div>
      ) : (
        <p className="text-sm leading-relaxed text-muted">
          Kein Readiness Wert im Zeitraum. Er entsteht aus einem Check-in.
        </p>
      )}
    </section>
  );
}
