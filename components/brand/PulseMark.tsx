// Team Performance OS — Wortmarke-Symbol: Readiness-Puls als Linie (Signature-Element,
// Design-Tokens v0.2). Reine Marke, keine Daten. Statisch, kein Animations-Loop.

export function PulseMark({ size = 24 }: { size?: number }) {
  return (
    <svg
      aria-hidden="true"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="var(--signal)"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M2 13h4l3-8 4 15 3-7h6" />
    </svg>
  );
}
