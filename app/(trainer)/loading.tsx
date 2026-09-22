// Team Performance OS — Ladezustand des Trainer-Segments.
// Reine Platzhalter in der Rasterstruktur des Dashboards, keine Werte.

export default function TrainerLoading() {
  return (
    <main
      className="mx-auto flex max-w-7xl flex-col gap-8 px-8 py-12"
      aria-busy="true"
      aria-live="polite"
    >
      <p className="text-sm text-muted">Kader wird geladen</p>
      <div className="grid grid-cols-1 gap-6 md:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: 6 }).map((_, index) => (
          <div
            key={index}
            className="h-48 rounded-lg border border-white/5 bg-panel motion-safe:animate-pulse"
          />
        ))}
      </div>
    </main>
  );
}
