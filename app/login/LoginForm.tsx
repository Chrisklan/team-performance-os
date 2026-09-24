"use client";

// Team Performance OS — Login-Formular mit zwei Wegen: Passwort (Standard) und Anmeldelink.
// Dazu "Passwort vergessen", das einen Link zum Zuruecksetzen schickt.
// Zustaende je Weg: Eingabe, wird gesendet, gesendet bzw. angemeldet, ungueltige
// Eingabe, Limit erreicht, Fehler.
// Die Mailadresse bleibt beim Wechsel zwischen den Wegen stehen.

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { useFormState, useFormStatus } from "react-dom";
import {
  requestMagicLink,
  requestPasswordReset,
  type LoginState,
} from "./actions";
import { createSupabaseBrowserClient } from "@/lib/supabase/browser";

type Mode = "password" | "link" | "reset";

const INITIAL: LoginState = { status: "idle" };
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

const INPUT_CLASS =
  "h-12 w-full rounded-md border border-muted bg-field px-4 text-base text-ink placeholder:text-muted focus:outline-none focus-visible:border-signal focus-visible:ring-2 focus-visible:ring-signal";
const PRIMARY_CLASS =
  "flex h-12 w-full items-center justify-center rounded-md bg-signal px-4 text-base font-bold text-field transition-colors hover:bg-signal/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-2 focus-visible:ring-offset-panel disabled:cursor-wait disabled:opacity-60";
const QUIET_LINK_CLASS =
  "h-12 self-start rounded-md text-sm font-bold text-signal underline-offset-4 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-signal";

export function LoginForm({ next }: { next: string }) {
  const [mode, setMode] = useState<Mode>("password");
  const [email, setEmail] = useState("");

  return (
    <div className="flex flex-col gap-6">
      {mode === "reset" ? null : (
        <div role="group" aria-label="Anmeldeweg" className="flex gap-6 border-b border-white/10">
          <ModeTab active={mode === "password"} onSelect={() => setMode("password")}>
            Mit Passwort
          </ModeTab>
          <ModeTab active={mode === "link"} onSelect={() => setMode("link")}>
            Mit Anmeldelink
          </ModeTab>
        </div>
      )}
      {mode === "password" ? (
        <PasswordForm
          next={next}
          email={email}
          onEmail={setEmail}
          onForgot={() => setMode("reset")}
        />
      ) : mode === "link" ? (
        <MailLinkForm key="link" kind="link" next={next} email={email} onEmail={setEmail} />
      ) : (
        <MailLinkForm
          key="reset"
          kind="reset"
          next={next}
          email={email}
          onEmail={setEmail}
          onBack={() => setMode("password")}
        />
      )}
    </div>
  );
}

function ModeTab({
  active,
  onSelect,
  children,
}: {
  active: boolean;
  onSelect: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onSelect}
      className={`-mb-px h-12 border-b-2 text-sm font-bold transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-signal ${
        active ? "border-signal text-ink" : "border-transparent text-muted hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

function EmailField({
  email,
  onEmail,
  describedBy,
  invalid,
}: {
  email: string;
  onEmail: (value: string) => void;
  describedBy: string | undefined;
  invalid: boolean;
}) {
  return (
    <div className="flex flex-col gap-2">
      <label htmlFor="email" className="text-sm font-bold text-ink">
        Mailadresse
      </label>
      <input
        id="email"
        name="email"
        type="email"
        inputMode="email"
        autoComplete="username"
        required
        value={email}
        onChange={(event) => onEmail(event.target.value)}
        aria-invalid={invalid ? true : undefined}
        aria-describedby={describedBy}
        className={INPUT_CLASS}
      />
    </div>
  );
}

// --- Passwort -----------------------------------------------------------------

type PasswordStatus =
  | "idle"
  | "pending"
  | "invalid_input"
  | "wrong_credentials"
  | "rate_limited"
  | "offline"
  | "failed";

const PASSWORD_MESSAGES: Record<Exclude<PasswordStatus, "idle" | "pending">, string> = {
  invalid_input: "Bitte gib deine Mailadresse und dein Passwort ein.",
  wrong_credentials:
    "Mailadresse oder Passwort stimmt nicht. Noch kein Passwort? Melde dich mit dem Anmeldelink an, danach kannst du eins festlegen.",
  rate_limited: "Zu viele Versuche. Warte einige Minuten und versuche es dann erneut.",
  offline: "Der Anmeldedienst ist nicht erreichbar. Prüfe deine Verbindung und versuche es erneut.",
  failed: "Die Anmeldung hat nicht geklappt. Versuche es erneut.",
};

function PasswordForm({
  next,
  email,
  onEmail,
  onForgot,
}: {
  next: string;
  email: string;
  onEmail: (value: string) => void;
  onForgot: () => void;
}) {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<PasswordStatus>("idle");

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const address = email.trim().toLowerCase();
    if (!EMAIL_PATTERN.test(address) || password.length === 0) {
      setStatus("invalid_input");
      return;
    }
    setStatus("pending");

    let error: { status?: number; code?: string; name?: string } | null = null;
    try {
      const supabase = createSupabaseBrowserClient();
      ({ error } = await supabase.auth.signInWithPassword({ email: address, password }));
    } catch {
      setStatus("offline");
      return;
    }

    if (!error) {
      // Server-Komponenten sollen die neuen Session-Cookies sehen.
      router.replace(next);
      router.refresh();
      return;
    }
    setPassword("");
    // email_not_confirmed wie falsche Daten behandeln: keine Auskunft, ob es das Konto gibt.
    if (error.code === "invalid_credentials" || error.code === "email_not_confirmed") {
      setStatus("wrong_credentials");
    } else if (error.status === 429 || error.code === "over_request_rate_limit") {
      setStatus("rate_limited");
    } else if (error.name === "AuthRetryableFetchError") {
      setStatus("offline");
    } else {
      setStatus("failed");
    }
  }

  const message = status === "idle" || status === "pending" ? null : PASSWORD_MESSAGES[status];
  const pending = status === "pending";

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-6" noValidate>
      <EmailField
        email={email}
        onEmail={onEmail}
        describedBy={message ? "login-message" : undefined}
        invalid={Boolean(message)}
      />
      <div className="flex flex-col gap-2">
        <label htmlFor="password" className="text-sm font-bold text-ink">
          Passwort
        </label>
        <input
          id="password"
          name="password"
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          aria-invalid={message ? true : undefined}
          aria-describedby={message ? "login-message" : undefined}
          className={INPUT_CLASS}
        />
        {message ? (
          <p id="login-message" role="alert" className="text-sm text-stop-ink">
            {message}
          </p>
        ) : null}
      </div>
      <button type="submit" disabled={pending} className={PRIMARY_CLASS}>
        {pending ? "Wird angemeldet" : "Anmelden"}
      </button>
      <button type="button" onClick={onForgot} className={QUIET_LINK_CLASS}>
        Passwort vergessen
      </button>
    </form>
  );
}

// --- Anmeldelink und Passwort zuruecksetzen -------------------------------------

const LINK_COPY = {
  link: {
    action: requestMagicLink,
    submit: "Anmeldelink senden",
    pending: "Link wird gesendet",
    hint: "Du bekommst einen Link per Mail. Ein Passwort brauchst du dafür nicht.",
    sentTitle: "Prüfe dein Postfach",
    sentBody: "freigeschaltet ist, kommt in Kürze ein Anmeldelink.",
    resend: "Link erneut senden",
    tooMany: "Es wurden zu viele Links angefordert.",
  },
  reset: {
    action: requestPasswordReset,
    submit: "Link zum Zurücksetzen senden",
    pending: "Link wird gesendet",
    hint: "Du bekommst einen Link per Mail. Darüber legst du ein neues Passwort fest.",
    sentTitle: "Prüfe dein Postfach",
    sentBody: "freigeschaltet ist, kommt in Kürze ein Link zum Zurücksetzen.",
    resend: "Link erneut senden",
    tooMany: "Es wurden zu viele Links angefordert.",
  },
} as const;

function SubmitButton({ label, pendingLabel }: { label: string; pendingLabel: string }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending} className={PRIMARY_CLASS}>
      {pending ? pendingLabel : label}
    </button>
  );
}

function MailLinkForm({
  kind,
  next,
  email,
  onEmail,
  onBack,
}: {
  kind: "link" | "reset";
  next: string;
  email: string;
  onEmail: (value: string) => void;
  onBack?: () => void;
}) {
  const copy = LINK_COPY[kind];
  const [state, formAction] = useFormState(copy.action, INITIAL);

  const backButton = onBack ? (
    <button type="button" onClick={onBack} className={QUIET_LINK_CLASS}>
      Zurück zur Anmeldung
    </button>
  ) : null;

  if (state.status === "sent") {
    return (
      <div className="flex flex-col gap-4" role="status" aria-live="polite">
        <h3 className="text-xl font-bold text-ink">{copy.sentTitle}</h3>
        <p className="text-base leading-relaxed text-muted">
          Wenn <span className="text-ink">{state.email}</span> für das Trainerteam{" "}
          {copy.sentBody} Öffne ihn in diesem Browser.
        </p>
        <form action={formAction}>
          <input type="hidden" name="next" value={next} />
          <input type="hidden" name="email" value={state.email} />
          <button type="submit" className={QUIET_LINK_CLASS}>
            {copy.resend}
          </button>
        </form>
        {backButton}
      </div>
    );
  }

  const message =
    state.status === "invalid"
      ? "Bitte gib eine gültige Mailadresse ein."
      : state.status === "rate_limited"
        ? `${copy.tooMany} Warte einige Minuten und versuche es dann erneut.`
        : state.status === "failed"
          ? "Der Link konnte nicht gesendet werden. Prüfe deine Verbindung und versuche es erneut."
          : null;

  return (
    <form action={formAction} className="flex flex-col gap-6" noValidate>
      {kind === "reset" ? (
        <h3 className="text-base font-bold text-ink">Passwort zurücksetzen</h3>
      ) : null}
      <input type="hidden" name="next" value={next} />
      <div className="flex flex-col gap-2">
        <EmailField
          email={email}
          onEmail={onEmail}
          describedBy={message ? "login-message" : "login-hint"}
          invalid={Boolean(message)}
        />
        {message ? (
          <p id="login-message" role="alert" className="text-sm text-stop-ink">
            {message}
          </p>
        ) : (
          <p id="login-hint" className="text-sm text-muted">
            {copy.hint}
          </p>
        )}
      </div>
      <SubmitButton label={copy.submit} pendingLabel={copy.pending} />
      {backButton}
    </form>
  );
}
