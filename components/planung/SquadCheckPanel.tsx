"use client";

// Team Performance OS — Pruefung Plan gegen Zustand (AP-69), Sicht des Trainerteams.
//
// Vier Spalten in fester Reihenfolge: volle Gruppe, reduziert, individuell,
// aussetzen. Keine Ampel und keine Farbe nach Schweregrad (MDR-Einordnung,
// wie die LoadDeviation-Sichten): die Spalte selbst traegt die Aussage, die
// Quelle steht als Wort daneben (Freigabe, Regel v1, KI Zuordnung).
// Hierarchie (Design-Codex 1b): die Spalten mit Abweichung von der vollen
// Gruppe tragen die Hinweise, die volle Gruppe ist eine ruhige Namensliste.
//
// Hinweise mit "×" klicken den Hinweis fuer diese Einheit teamweit weg
// (public.rpc_dismiss_session_hint). Freigabe-Spiegel und der Info-Hinweis
// "noch keine Meldung" haben kein "×": die Tuer lehnt sie ohnehin ab.
// Der Knopf "KI Zuordnung pruefen" erscheint nur, wenn der Team-Schalter und
// der Betreiber-Notaus an sind und die Einheit gespeichert ist. Jeder Fehler
// dort faellt auf die Regelpruefung v1 zurueck und steht in der Statuszeile.

import { useMemo, useState, useTransition } from "react";
import { dismissSessionHint, restoreSessionHint, runJevSquadCheck } from "@/lib/planung/squadCheckActions";
import { mergeOverlays, type SquadAthleteView } from "@/lib/planung/jevSquadCheck";
import type {
  DismissableHintKey,
  JevRunResult,
  SquadCheckPayload,
  Suggestion,
} from "@/lib/planung/types";

const BUTTON =
  "flex h-12 items-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

const COLUMN_LABEL: Record<Suggestion, string> = {
  full: "Volle Gruppe",
  reduced: "Reduziert",
  individual: "Individuell",
  suspend: "Aussetzen",
};

const HINT_LABEL: Record<string, string> = {
  h1: "Band heute niedrig",
  h2: "Geplante Last über eigener Norm",
  h3: "Heute noch keine Meldung",
  h4: "Freigegebene Abweichung in 7 Tagen",
  j1: "KI Zuordnung: reduziert",
};

const LOAD_LABEL: Record<string, string> = {
  far_above: "deutlich über eigener Norm",
  above: "über eigener Norm",
  normal: "im Rahmen der eigenen Norm",
  below: "unter eigener Norm",
  no_norm: "noch keine eigene Norm",
};

const JEV_STATUS: Record<JevRunResult["status"], string> = {
  off: "KI Zuordnung ist vom Betreiber ausgeschaltet. Es gilt die Regelprüfung v1.",
  fallback: "KI Zuordnung war nicht verfügbar. Es gilt die Regelprüfung v1.",
  no_candidates: "Keine Spielerin mit offenem Hinweis in der vollen Gruppe. Nichts ging an die KI Zuordnung.",
  ok: "KI Zuordnung geprüft.",
  partial: "KI Zuordnung nur teilweise beantwortet. Für den Rest gilt die Regelprüfung v1.",
};

// h2 nennt die Laststufe gleich mit ("deutlich ueber" bei z >= 2), als Wort,
// nie als Zahl.
function chipLabel(key: string, a: SquadAthleteView): string {
  if (key === "h2") return `Geplante Last ${LOAD_LABEL[a.load_level] ?? "über eigener Norm"}`;
  return HINT_LABEL[key] ?? key;
}

function sourceLabel(a: SquadAthleteView): string {
  if (a.jev) return "KI Zuordnung";
  return a.source === "mirror" ? "Freigabe" : "Regel v1";
}

type Props = {
  payload: SquadCheckPayload | null;
  checkError: string | null;
  sessionId: string | null;
  durationMin: number;
  intensity: number;
  showJevButton: boolean;
  onChanged: () => void;
};

export function SquadCheckPanel({
  payload,
  checkError,
  sessionId,
  durationMin,
  intensity,
  showJevButton,
  onChanged,
}: Props) {
  const [jev, setJev] = useState<JevRunResult | null>(null);
  const [jevPending, startJev] = useTransition();
  const [hintPending, startHint] = useTransition();
  const [hintError, setHintError] = useState<string | null>(null);

  const athletes = useMemo(
    () => (payload ? mergeOverlays(payload.athletes, jev?.overlays ?? []) : []),
    [payload, jev],
  );

  const columns = useMemo(() => {
    const out: Record<Suggestion, SquadAthleteView[]> = { full: [], reduced: [], individual: [], suspend: [] };
    for (const a of athletes) out[a.suggestion].push(a);
    return out;
  }, [athletes]);

  function runJev() {
    if (!sessionId) return;
    startJev(async () => {
      const result = await runJevSquadCheck(sessionId, durationMin, intensity);
      setJev(result);
    });
  }

  function changeHint(personId: string, hintKey: DismissableHintKey, action: "dismiss" | "restore") {
    if (!sessionId) return;
    setHintError(null);
    startHint(async () => {
      const result =
        action === "dismiss"
          ? await dismissSessionHint(sessionId, personId, hintKey)
          : await restoreSessionHint(sessionId, personId, hintKey);
      if (!result.ok) {
        setHintError(result.message);
        return;
      }
      if (hintKey === "j1" && action === "dismiss" && jev) {
        setJev({ ...jev, overlays: jev.overlays.filter((o) => o.person_id !== personId) });
      }
      onChanged();
    });
  }

  if (checkError) {
    return (
      <section className="flex flex-col gap-2 border-l-2 border-stop-ink py-1 pl-4" aria-live="polite">
        <p className="text-xs font-bold uppercase tracking-wide text-muted">Plan gegen Zustand</p>
        <p role="alert" className="text-sm text-stop-ink">
          {checkError}
        </p>
      </section>
    );
  }

  if (!payload) {
    return (
      <section className="flex flex-col gap-2 border-l-2 border-muted py-1 pl-4">
        <p className="text-xs font-bold uppercase tracking-wide text-muted">Plan gegen Zustand</p>
        <p className="max-w-prose text-sm leading-relaxed text-muted">
          Datum, Dauer und Intensität eintragen und „Prüfen“ wählen. Die Prüfung hält die geplante Einheit gegen den
          heutigen Zustand jeder Spielerin.
        </p>
      </section>
    );
  }

  return (
    <section className="flex flex-col gap-6" aria-busy={hintPending || jevPending}>
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="flex flex-col gap-1">
          <p className="text-xs font-bold uppercase tracking-wide text-muted">
            Plan gegen Zustand · Regelprüfung {payload.rule_version}
          </p>
          <p className="text-sm text-muted">
            Geplante Tageslast {payload.planned_day_load} (Intensität mal Minuten, alle Einheiten des Tages)
          </p>
        </div>
        {showJevButton && sessionId ? (
          <button type="button" className={BUTTON} disabled={jevPending} onClick={runJev}>
            {jevPending ? "KI Zuordnung läuft" : "KI Zuordnung prüfen"}
          </button>
        ) : null}
      </div>

      {jev ? (
        <p className="text-sm text-muted" role="status">
          {JEV_STATUS[jev.status]}
          {jev.status === "ok" || jev.status === "partial"
            ? ` ${jev.overlays.length === 1 ? "Ein Hinweis" : `${jev.overlays.length} Hinweise`} auf reduziert.`
            : ""}
        </p>
      ) : null}
      {hintError ? (
        <p role="alert" className="text-sm text-stop-ink">
          {hintError}
        </p>
      ) : null}

      <div className="grid grid-cols-1 gap-8 md:grid-cols-2 xl:grid-cols-4">
        {(Object.keys(COLUMN_LABEL) as Suggestion[]).map((key) => (
          <div key={key} className="flex flex-col gap-3">
            <h3 className="flex items-baseline justify-between gap-2 border-b border-muted/40 pb-2">
              <span className="font-display text-lg font-bold uppercase text-ink">{COLUMN_LABEL[key]}</span>
              <span className="text-sm text-muted">{columns[key].length}</span>
            </h3>
            {columns[key].length === 0 ? (
              <p className="text-sm text-muted">Niemand</p>
            ) : (
              <ul className="flex flex-col gap-4">
                {columns[key].map((a) => (
                  <AthleteRow
                    key={a.person_id}
                    athlete={a}
                    canDismiss={sessionId !== null && a.source === "rule"}
                    busy={hintPending}
                    onHint={changeHint}
                  />
                ))}
              </ul>
            )}
          </div>
        ))}
      </div>

      <p className="max-w-prose text-sm leading-relaxed text-muted">
        Die Spalten beschreiben den Plan gegen den heutigen Zustand. Aussetzen, individuell und reduziert mit der
        Quelle Freigabe folgen der ärztlichen Freigabe und sind nicht verhandelbar. Die Entscheidung über die Gruppe
        trifft das Trainerteam.
      </p>
    </section>
  );
}

function AthleteRow({
  athlete,
  canDismiss,
  busy,
  onHint,
}: {
  athlete: SquadAthleteView;
  canDismiss: boolean;
  busy: boolean;
  onHint: (personId: string, hintKey: DismissableHintKey, action: "dismiss" | "restore") => void;
}) {
  const name = `${athlete.jersey !== null ? `${athlete.jersey} ` : ""}${athlete.display_name}`;
  const chips: { key: string; dismissable: boolean }[] = athlete.hints.map((h) => ({
    key: h,
    dismissable: canDismiss && h !== "h3",
  }));
  if (athlete.jev) chips.push({ key: "j1", dismissable: canDismiss });
  const dismissed = athlete.dismissed_hints;

  return (
    <li className="flex flex-col gap-2">
      <p className="flex flex-wrap items-baseline gap-x-2 text-base text-ink">
        <span className="font-bold">{name}</span>
        <span className="text-xs uppercase tracking-wide text-muted">{sourceLabel(athlete)}</span>
      </p>
      {chips.length > 0 ? (
        <ul className="flex flex-wrap gap-2" aria-label={`Hinweise zu ${name}`}>
          {chips.map((c) => (
            <li key={c.key} className="flex h-12 items-center rounded-md border border-muted/60 text-sm text-ink">
              <span className="px-3">{chipLabel(c.key, athlete)}</span>
              {c.dismissable ? (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => onHint(athlete.person_id, c.key as DismissableHintKey, "dismiss")}
                  aria-label={`Hinweis ausblenden: ${chipLabel(c.key, athlete)}`}
                  className="flex h-12 w-12 items-center justify-center rounded-md border-l border-muted/60 text-lg text-muted transition-colors hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60"
                >
                  ×
                </button>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
      {canDismiss && dismissed.length > 0 ? (
        <p className="flex flex-wrap items-center gap-x-2 text-sm text-muted">
          <span>Ausgeblendet:</span>
          {dismissed.map((d) => (
            <button
              key={d}
              type="button"
              disabled={busy}
              onClick={() => onHint(athlete.person_id, d, "restore")}
              className="flex h-12 items-center underline decoration-muted underline-offset-4 transition-colors hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait"
              aria-label={`Wieder einblenden: ${HINT_LABEL[d] ?? d}`}
            >
              {HINT_LABEL[d] ?? d}
            </button>
          ))}
        </p>
      ) : null}
    </li>
  );
}
