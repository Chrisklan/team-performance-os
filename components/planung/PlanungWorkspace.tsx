"use client";

// Team Performance OS — Planung einer Einheit plus Pruefung Plan gegen Zustand (AP-69).
//
// Links das Formular (schmale Spalte), rechts die Pruefung (breite Spalte):
// bewusst ungleiche Spalten, die Pruefung ist das dominante Element der Seite
// (Design-Codex 1b). Ein Entwurf laesst sich pruefen, ohne ihn zu speichern.
// Wegklicken und KI Zuordnung brauchen eine gespeicherte Einheit, weil beide
// an die Einheit gebunden sind (Wegklick teamweit, Protokollzeile mit context_ref).
// Solange das Formular vom gespeicherten Stand abweicht, bleibt der Knopf fuer
// die KI Zuordnung weg: sonst liefe sie gegen andere Werte als die gespeicherten.

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { SquadCheckPanel } from "./SquadCheckPanel";
import { runSquadCheck } from "@/lib/planung/squadCheckActions";
import { saveTrainingSession } from "@/lib/planung/sessionActions";
import { SESSION_TYPES, type SessionType, type SquadCheckPayload, type TrainingSession } from "@/lib/planung/types";

const INPUT =
  "h-12 w-full rounded-md border border-muted bg-field px-4 text-base text-ink placeholder:text-muted focus:outline-none focus-visible:border-signal focus-visible:ring-2 focus-visible:ring-signal";
const LABEL = "text-sm font-bold text-ink";
const PRIMARY =
  "flex h-12 items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-panel disabled:cursor-wait disabled:opacity-60";
const SECONDARY =
  "flex h-12 items-center rounded-md border border-muted px-4 text-sm font-bold text-ink transition-colors hover:border-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal disabled:cursor-wait disabled:opacity-60";

const TYPE_LABEL: Record<SessionType, string> = {
  field: "Platz",
  gym: "Kraftraum",
  recovery: "Regeneration",
  tactical: "Taktik",
  test: "Leistungstest",
};

type FormState = {
  sessionDate: string;
  startTime: string;
  durationMin: string;
  sessionType: SessionType;
  intensity: string;
  goalText: string;
};

function fromSession(s: TrainingSession | null, defaultDate: string): FormState {
  return {
    sessionDate: s?.session_date ?? defaultDate,
    startTime: s?.start_time ? s.start_time.slice(0, 5) : "",
    durationMin: s ? String(s.duration_min) : "90",
    sessionType: s?.session_type ?? "field",
    intensity: s?.planned_intensity ? String(s.planned_intensity) : "",
    goalText: s?.goal_text ?? "",
  };
}

function sameForm(a: FormState, b: FormState): boolean {
  return (
    a.sessionDate === b.sessionDate &&
    a.startTime === b.startTime &&
    a.durationMin === b.durationMin &&
    a.sessionType === b.sessionType &&
    a.intensity === b.intensity &&
    a.goalText.trim() === b.goalText.trim()
  );
}

export function PlanungWorkspace({
  initialSession,
  initialCheck,
  initialCheckError,
  defaultDate,
  jevAvailable,
}: {
  initialSession: TrainingSession | null;
  initialCheck: SquadCheckPayload | null;
  initialCheckError: string | null;
  defaultDate: string;
  jevAvailable: boolean;
}) {
  const router = useRouter();
  const [sessionId, setSessionId] = useState<string | null>(initialSession?.id ?? null);
  const [form, setForm] = useState<FormState>(() => fromSession(initialSession, defaultDate));
  const [saved, setSaved] = useState<FormState | null>(() =>
    initialSession ? fromSession(initialSession, defaultDate) : null,
  );
  const [check, setCheck] = useState<SquadCheckPayload | null>(initialCheck);
  const [checkError, setCheckError] = useState<string | null>(initialCheckError);
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  const dirty = saved === null || !sameForm(form, saved);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((f) => ({ ...f, [key]: value }));
    setNotice(null);
  }

  async function performCheck(values: FormState, id: string | null) {
    const result = await runSquadCheck({
      sessionDate: values.sessionDate,
      durationMin: Number(values.durationMin),
      intensity: Number(values.intensity),
      sessionId: id,
    });
    if (result.ok) {
      setCheck(result.payload);
      setCheckError(null);
    } else {
      setCheckError(result.message);
    }
  }

  function onCheck() {
    setFormError(null);
    startTransition(() => performCheck(form, dirty ? null : sessionId));
  }

  function onSave() {
    setFormError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await saveTrainingSession({
        sessionId,
        sessionDate: form.sessionDate,
        startTime: form.startTime ? form.startTime : null,
        durationMin: Number(form.durationMin),
        sessionType: form.sessionType,
        intensity: Number(form.intensity),
        goalText: form.goalText,
      });
      if (!result.ok) {
        setFormError(result.message);
        return;
      }
      const snapshot = fromSession(result.session, defaultDate);
      setSessionId(result.session.id);
      setForm(snapshot);
      setSaved(snapshot);
      setNotice(sessionId ? "Änderungen gespeichert." : "Einheit gespeichert.");
      router.replace(`/planung?session=${result.session.id}`, { scroll: false });
      await performCheck(snapshot, result.session.id);
    });
  }

  function recheckSaved() {
    startTransition(() => performCheck(saved ?? form, dirty ? null : sessionId));
  }

  return (
    <div className="grid grid-cols-1 gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,3fr)]">
      <form
        className="flex flex-col gap-6"
        onSubmit={(e) => {
          e.preventDefault();
          onSave();
        }}
        noValidate
      >
        <p className="text-xs font-bold uppercase tracking-wide text-muted">
          {sessionId ? "Einheit bearbeiten" : "Neue Einheit"}
        </p>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-date" className={LABEL}>Datum</label>
          <input id="session-date" type="date" className={INPUT} value={form.sessionDate}
            onChange={(e) => update("sessionDate", e.target.value)} required />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-start" className={LABEL}>Beginn</label>
          <input id="session-start" type="time" className={INPUT} value={form.startTime}
            onChange={(e) => update("startTime", e.target.value)} />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-duration" className={LABEL}>Dauer in Minuten</label>
          <input id="session-duration" type="number" inputMode="numeric" min={1} max={300} className={INPUT}
            value={form.durationMin} onChange={(e) => update("durationMin", e.target.value)} required />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-intensity" className={LABEL}>Geplante Intensität (1 bis 10)</label>
          <input id="session-intensity" type="number" inputMode="numeric" min={1} max={10} className={INPUT}
            value={form.intensity} onChange={(e) => update("intensity", e.target.value)} required />
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-type" className={LABEL}>Art der Einheit</label>
          <select id="session-type" className={INPUT} value={form.sessionType}
            onChange={(e) => update("sessionType", e.target.value as SessionType)}>
            {SESSION_TYPES.map((t) => (
              <option key={t} value={t}>{TYPE_LABEL[t]}</option>
            ))}
          </select>
        </div>
        <div className="flex flex-col gap-2">
          <label htmlFor="session-goal" className={LABEL}>Ziel der Einheit</label>
          <textarea id="session-goal" rows={3} maxLength={2000}
            className="w-full rounded-md border border-muted bg-field px-4 py-3 text-base text-ink placeholder:text-muted focus:outline-none focus-visible:border-signal focus-visible:ring-2 focus-visible:ring-signal"
            value={form.goalText} onChange={(e) => update("goalText", e.target.value)} />
        </div>
        {formError ? <p role="alert" className="text-sm text-stop-ink">{formError}</p> : null}
        {notice ? <p role="status" className="text-sm text-muted">{notice}</p> : null}
        <div className="flex flex-wrap gap-3">
          <button type="submit" className={PRIMARY} disabled={isPending}>
            {isPending ? "Wird gespeichert" : sessionId ? "Änderungen speichern" : "Einheit speichern"}
          </button>
          <button type="button" className={SECONDARY} disabled={isPending} onClick={onCheck}>
            Prüfen
          </button>
        </div>
        {sessionId && dirty ? (
          <p className="text-sm text-muted">
            Ungespeicherte Änderungen: die Prüfung läuft als Entwurf, ohne ausgeblendete Hinweise.
          </p>
        ) : null}
      </form>

      <SquadCheckPanel
        payload={check}
        checkError={checkError}
        sessionId={dirty ? null : sessionId}
        durationMin={Number((saved ?? form).durationMin)}
        intensity={Number((saved ?? form).intensity)}
        showJevButton={jevAvailable && !dirty && sessionId !== null}
        onChanged={recheckSaved}
      />
    </div>
  );
}
