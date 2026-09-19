// Team Performance OS — Anmeldung fuer das Trainerteam (Magic-Link).
// Komposition: dominante Aussage links (7 Teile), ruhige Formularflaeche rechts (5 Teile),
// beide auf derselben Mittelachse. Wortmarke oben links.
// Tablet und Phone stapeln: Aussage oben, Formular darunter.

import type { Metadata } from "next";
import { LoginForm } from "./LoginForm";
import { PulseMark } from "@/components/brand/PulseMark";
import { safeNextPath } from "@/lib/supabase/auth-redirect";

export const metadata: Metadata = {
  title: "Anmelden · Team Performance OS",
};

const NOTICES: Record<string, string> = {
  callback:
    "Der Anmeldelink ist abgelaufen oder wurde schon verwendet. Fordere unten einen neuen an.",
  signedout: "Du bist abgemeldet.",
};

export default function LoginPage({
  searchParams,
}: {
  searchParams: { next?: string; error?: string; notice?: string };
}) {
  const next = safeNextPath(searchParams.next);
  const notice = NOTICES[searchParams.error ?? searchParams.notice ?? ""];
  const isError = Boolean(searchParams.error && NOTICES[searchParams.error]);

  return (
    <main className="grid min-h-screen grid-cols-1 grid-rows-[auto_1fr] lg:grid-cols-[7fr_5fr] lg:grid-rows-1">
      <section className="flex flex-col gap-12 px-6 py-8 lg:px-12 lg:py-12">
        <div className="flex items-center gap-3 text-ink">
          <PulseMark />
          <span className="text-base font-bold">Team Performance OS</span>
        </div>
        <div className="flex max-w-2xl flex-col gap-4 lg:my-auto">
          <h1 className="text-3xl font-bold leading-tight tracking-tight text-ink lg:text-4xl">
            Der Kader am Morgen, in unter 60 Sekunden.
          </h1>
          <p className="max-w-xl text-base leading-relaxed text-muted">
            Readiness, Auffälligkeiten und Belegung des Tages an einem Ort. Die
            Anzeige beschreibt, sie stellt keine Diagnose.
          </p>
        </div>
      </section>

      <section className="flex flex-col justify-start gap-6 border-t border-white/5 bg-surface-card px-6 py-12 lg:justify-center lg:border-l lg:border-t-0 lg:px-12">
        <div className="flex w-full max-w-md flex-col gap-6">
          <h2 className="text-xl font-bold text-ink">Anmelden</h2>
          {notice ? (
            <p
              role={isError ? "alert" : "status"}
              className={`rounded-md border px-4 py-3 text-sm ${
                isError
                  ? "border-warn/60 text-warn-text"
                  : "border-white/10 text-muted"
              }`}
            >
              {notice}
            </p>
          ) : null}
          <LoginForm next={next} />
          <p className="text-sm text-muted">
            Nur für freigeschaltete Konten des Trainerteams.
          </p>
        </div>
      </section>
    </main>
  );
}
