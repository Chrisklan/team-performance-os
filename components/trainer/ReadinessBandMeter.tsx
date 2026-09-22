// Team Performance OS — ReadinessBandMeter.
// Zeigt die Bereitschaft als Zustandsklasse, nicht als Zahl. Seit Migration
// 20260922000033 (Befund N7) liefert app.rpc_morning_ops dem Trainerteam nur
// noch readiness.band; score_total und die Faktoren sind Medizin und der
// eigenen Person vorbehalten (Modul Rollen und Medizin Gate, Abschnitt 5).
//
// Form: drei Segmente in einer Reihe, links niedrig, rechts hoch. Genau ein
// Segment traegt Farbe, die Position sagt die Stufe auch ohne Farbe. Bewusst
// KEIN gefuellter Balken bis zur Stufe: ein gefuellter Balken liest sich als
// Menge und lockt zurueck zum Zahlenvergleich, den dieses Bauteil beendet.
// Dieselbe Logik traegt das Signature Element Kaderleiste (docs/design/README).
//
// Farben aus den v1.0 Datenvisualisierungs Tokens. Die niedrige Stufe nimmt
// stop-ink statt stop, weil stop auf der Kartenflaeche panel nur 2,43 zu 1
// erreicht und die Handwerksregel 3 zu 1 fuer UI Elemente verlangt. Gerechnet
// gegen panel #063E75: stop #E23D3D = 2,43, stop-ink #FF8A8A = 4,52,
// caution #F2711C = 3,50, clear #3DD68C = 5,47.
// Statisches Markup, keine Animation, damit auch ohne Reduced Motion nichts wackelt.

import { BAND_ORDER, bandLabel } from "@/lib/trainer/aggregate";
import type { ReadinessBand } from "@/lib/trainer/types";

const BAND_FILL: Record<ReadinessBand, string> = {
  low: "bg-stop-ink",
  moderate: "bg-caution",
  high: "bg-clear",
};

type ReadinessBandMeterProps = {
  band: ReadinessBand | null;
  variant?: "compact" | "large";
};

export function ReadinessBandMeter({
  band,
  variant = "compact",
}: ReadinessBandMeterProps) {
  const segment = variant === "large" ? "h-3 w-16" : "h-2 w-8";
  const label = variant === "large" ? "text-xl" : "text-lg";

  return (
    <div className="flex flex-col gap-2">
      <div className="flex gap-1" aria-hidden="true">
        {BAND_ORDER.map((step) => (
          <span
            key={step}
            className={`${segment} ${
              band === step ? BAND_FILL[step] : "bg-white/10"
            }`}
          />
        ))}
      </div>
      <p
        className={`font-display font-bold uppercase tracking-wide ${label} ${
          band ? "text-ink" : "text-muted"
        }`}
      >
        {band ? bandLabel(band) : "Kein Check-in"}
      </p>
    </div>
  );
}
