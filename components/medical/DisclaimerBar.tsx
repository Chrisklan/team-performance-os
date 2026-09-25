// Team Performance OS — feststehender Hinweis ueber jeder LoadDeviation-Ansicht
// (Modul-LoadDeviation.md Abschnitt 6). Nicht ausblendbar, Wortlaut aus der Spec
// woertlich uebernommen. Gleiche Optik wie der linksbuendige Akzent bei den
// offenen Vorschlaegen in ClearanceBlock, keine eigene neue Bauform.

export function DisclaimerBar() {
  return (
    <div className="flex flex-col gap-1 border-l-2 border-muted py-1 pl-4">
      <p className="text-xs font-bold uppercase tracking-wide text-muted">Hinweis</p>
      <p className="max-w-prose text-sm leading-relaxed text-ink">
        Diese Ansicht beschreibt Abweichungen von historischen Werten. Sie trifft keine Aussage
        über Verletzungen oder Gesundheit.
      </p>
    </div>
  );
}
