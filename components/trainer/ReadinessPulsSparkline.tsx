// Team Performance OS — ReadinessPulsSparkline (Signature-Element).
// Deskriptiver Mini-Trend der Baseline-Serie gegen den rollenden Schnitt.
// Statisches SVG, keine Animations-Loop -> respektiert Reduced-Motion nativ.

type ReadinessPulsSparklineProps = {
  series: number[];
  rollingAvg: number;
  width?: number;
  height?: number;
  variant?: "compact" | "large";
  ariaLabel: string;
};

export function ReadinessPulsSparkline({
  series,
  rollingAvg,
  width = 88,
  height = 28,
  variant = "compact",
  ariaLabel,
}: ReadinessPulsSparklineProps) {
  if (series.length < 2) return null;

  const min = Math.min(...series, rollingAvg);
  const max = Math.max(...series, rollingAvg);
  const range = max - min || 1;
  const stepX = width / (series.length - 1);
  const padding = variant === "large" ? 4 : 2;
  const toY = (value: number) =>
    padding + (height - padding * 2) * (1 - (value - min) / range);

  const points = series
    .map((value, index) => `${index * stepX},${toY(value)}`)
    .join(" ");
  const lastValue = series[series.length - 1];
  const lastX = (series.length - 1) * stepX;
  const lastY = toY(lastValue);
  const avgY = toY(rollingAvg);
  // needs_decision an Chris (AP-54): "ok" hat in v1.0 keinen Anker, Wert aus v0.5 unveraendert.
  const strokeColor = lastValue < rollingAvg ? "var(--stop)" : "var(--legacy-ok)";

  return (
    <svg
      role="img"
      aria-label={ariaLabel}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      className="shrink-0"
    >
      <line
        x1={0}
        y1={avgY}
        x2={width}
        y2={avgY}
        stroke="var(--muted)"
        strokeWidth={1}
        strokeDasharray="2 2"
      />
      <polyline
        points={points}
        fill="none"
        stroke={strokeColor}
        strokeWidth={variant === "large" ? 2 : 1.5}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <circle
        cx={lastX}
        cy={lastY}
        r={variant === "large" ? 3 : 2}
        fill={strokeColor}
      />
    </svg>
  );
}
