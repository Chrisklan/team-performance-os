"use client";

// Team Performance OS — Login-Formular (Magic-Link).
// Zustaende: Eingabe, wird gesendet, gesendet, ungueltige Adresse, Mail-Limit, Fehler.

import { useFormState, useFormStatus } from "react-dom";
import { requestMagicLink, type LoginState } from "./actions";

const INITIAL: LoginState = { status: "idle" };

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      className="flex h-12 w-full items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-panel disabled:cursor-wait disabled:opacity-60"
    >
      {pending ? "Link wird gesendet" : "Anmeldelink senden"}
    </button>
  );
}

export function LoginForm({ next }: { next: string }) {
  const [state, formAction] = useFormState(requestMagicLink, INITIAL);

  if (state.status === "sent") {
    return (
      <div className="flex flex-col gap-4" role="status" aria-live="polite">
        <h2 className="text-xl font-bold text-ink">Prüfe dein Postfach</h2>
        <p className="text-base leading-relaxed text-muted">
          Wenn <span className="text-ink">{state.email}</span> für das Trainerteam
          freigeschaltet ist, kommt in Kürze ein Anmeldelink. Öffne ihn in diesem
          Browser.
        </p>
        <form action={formAction}>
          <input type="hidden" name="next" value={next} />
          <input type="hidden" name="email" value={state.email} />
          <button
            type="submit"
            className="h-12 rounded-md px-3 text-sm font-bold text-signal underline-offset-4 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
          >
            Link erneut senden
          </button>
        </form>
      </div>
    );
  }

  const message =
    state.status === "invalid"
      ? "Bitte gib eine gültige Mailadresse ein."
      : state.status === "rate_limited"
        ? "Es wurden zu viele Links angefordert. Warte einige Minuten und versuche es dann erneut."
        : state.status === "failed"
          ? "Der Link konnte nicht gesendet werden. Prüfe deine Verbindung und versuche es erneut."
          : null;

  return (
    <form action={formAction} className="flex flex-col gap-6" noValidate>
      <input type="hidden" name="next" value={next} />
      <div className="flex flex-col gap-2">
        <label htmlFor="email" className="text-sm font-bold text-ink">
          Mailadresse
        </label>
        <input
          id="email"
          name="email"
          type="email"
          inputMode="email"
          autoComplete="email"
          required
          defaultValue={"email" in state ? state.email : ""}
          aria-invalid={message ? true : undefined}
          aria-describedby={message ? "login-message" : "login-hint"}
          className="h-12 w-full rounded-md border border-muted bg-field px-4 text-base text-ink placeholder:text-muted focus:outline-none focus-visible:border-signal focus-visible:ring-2 focus-visible:ring-signal"
        />
        {message ? (
          <p id="login-message" role="alert" className="text-sm text-stop-ink">
            {message}
          </p>
        ) : (
          <p id="login-hint" className="text-sm text-muted">
            Du bekommst einen Link per Mail. Ein Passwort brauchst du nicht.
          </p>
        )}
      </div>
      <SubmitButton />
    </form>
  );
}
