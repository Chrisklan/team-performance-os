"use client";

// Team Performance OS — Formular "Passwort festlegen".
// Zustaende: Eingabe, wird gespeichert, zu kurz, zu lang, Bestaetigung weicht ab,
// gleiches Passwort wie bisher, vom Server als zu schwach abgelehnt, Sitzung weg,
// Limit erreicht, Fehler. Bei Erfolg leitet die Server Action weiter.

import { useFormState, useFormStatus } from "react-dom";
import { setOwnPassword, type SetPasswordState } from "./actions";
import { PASSWORD_MIN_LENGTH } from "@/lib/supabase/password";

const INITIAL: SetPasswordState = { status: "idle" };

const INPUT_CLASS =
  "h-12 w-full rounded-md border border-muted bg-field px-4 text-base text-ink focus:outline-none focus-visible:border-signal focus-visible:ring-2 focus-visible:ring-signal";

const MESSAGES: Record<Exclude<SetPasswordState["status"], "idle">, string> = {
  too_short: `Das Passwort braucht mindestens ${PASSWORD_MIN_LENGTH} Zeichen.`,
  too_long: "Das Passwort ist zu lang. Nimm höchstens 72 Zeichen, Umlaute zählen doppelt.",
  mismatch: "Die beiden Eingaben stimmen nicht überein.",
  same_password: "Das ist schon dein aktuelles Passwort. Wähle ein anderes.",
  weak: "Das Passwort ist zu schwach. Nimm ein längeres, das du sonst nirgends verwendest.",
  unauthenticated: "Deine Sitzung ist abgelaufen. Melde dich neu an und versuche es dann erneut.",
  rate_limited: "Zu viele Versuche. Warte einige Minuten und versuche es dann erneut.",
  failed: "Das Passwort konnte nicht gespeichert werden. Prüfe deine Verbindung und versuche es erneut.",
};

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      className="flex h-12 w-full items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-panel disabled:cursor-wait disabled:opacity-60"
    >
      {pending ? "Wird gespeichert" : "Passwort speichern"}
    </button>
  );
}

export function PasswordForm({ email, next }: { email: string; next: string | null }) {
  const [state, formAction] = useFormState(setOwnPassword, INITIAL);
  const message = state.status === "idle" ? null : MESSAGES[state.status];
  const confirmProblem = state.status === "mismatch";

  return (
    <form action={formAction} className="flex flex-col gap-6" noValidate>
      {next ? <input type="hidden" name="next" value={next} /> : null}
      {/* Fuer Passwortmanager: zu welchem Konto das neue Passwort gehoert. */}
      <input type="email" name="username" autoComplete="username" value={email} readOnly hidden />
      <div className="flex flex-col gap-2">
        <label htmlFor="password" className="text-sm font-bold text-ink">
          Neues Passwort
        </label>
        <input
          id="password"
          name="password"
          type="password"
          autoComplete="new-password"
          required
          minLength={PASSWORD_MIN_LENGTH}
          aria-invalid={message && !confirmProblem ? true : undefined}
          aria-describedby={message && !confirmProblem ? "password-message" : "password-hint"}
          className={INPUT_CLASS}
        />
        {message && !confirmProblem ? (
          <p id="password-message" role="alert" className="text-sm text-stop-ink">
            {message}
          </p>
        ) : (
          <p id="password-hint" className="text-sm text-muted">
            Mindestens {PASSWORD_MIN_LENGTH} Zeichen. Ein Satz aus mehreren Wörtern ist sicher und
            leicht zu merken.
          </p>
        )}
      </div>
      <div className="flex flex-col gap-2">
        <label htmlFor="confirm" className="text-sm font-bold text-ink">
          Passwort wiederholen
        </label>
        <input
          id="confirm"
          name="confirm"
          type="password"
          autoComplete="new-password"
          required
          aria-invalid={confirmProblem ? true : undefined}
          aria-describedby={confirmProblem ? "confirm-message" : undefined}
          className={INPUT_CLASS}
        />
        {confirmProblem ? (
          <p id="confirm-message" role="alert" className="text-sm text-stop-ink">
            {message}
          </p>
        ) : null}
      </div>
      <SubmitButton />
    </form>
  );
}
