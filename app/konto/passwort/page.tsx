// Team Performance OS — eigenes Passwort festlegen.
// Drei Wege hierher:
//  * nach dem Anmeldelink, wenn das Konto noch kein Passwort hat (?next=..., ueberspringbar)
//  * aus "Passwort vergessen" (Link aus der Mail, Sitzung kommt aus /auth/callback)
//  * direkt als angemeldete Person, um das Passwort zu aendern
// Gleiche Komposition wie /login, damit der Schritt als Teil der Anmeldung lesbar bleibt.

import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { PasswordForm } from "./PasswordForm";
import { PulseMark } from "@/components/brand/PulseMark";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/supabase/auth-redirect";
import { hasOwnPassword } from "@/lib/supabase/password";
import { appRoleFromClaims, homePathForRole } from "@/lib/medical/role";

export const metadata: Metadata = {
  title: "Passwort festlegen · Team Performance OS",
};

export default async function PasswordPage({
  searchParams,
}: {
  searchParams: { next?: string };
}) {
  const supabase = createSupabaseServerClient();
  const { data } = await supabase.auth.getUser();
  if (!data.user) redirect("/login?next=/konto/passwort");

  const hasPassword = hasOwnPassword(data.user.user_metadata);
  // Das Angebot nach dem Anmeldelink traegt ein next. Ohne next: Ruecksetzen oder Aendern.
  const offer = Boolean(searchParams.next) && !hasPassword;
  const next = searchParams.next ? safeNextPath(searchParams.next) : null;
  const { data: claimData } = await supabase.auth.getClaims();
  const leavePath = next ?? homePathForRole(appRoleFromClaims(claimData?.claims));

  return (
    <main className="grid min-h-screen grid-cols-1 grid-rows-[auto_1fr] lg:grid-cols-[7fr_5fr] lg:grid-rows-1">
      <section className="flex flex-col gap-12 px-6 py-8 lg:px-12 lg:py-12">
        <div className="flex items-center gap-3 text-ink">
          <PulseMark />
          <span className="text-base font-bold">Team Performance OS</span>
        </div>
        <div className="flex max-w-2xl flex-col gap-4 lg:my-auto">
          <h1 className="text-3xl font-bold leading-tight tracking-tight text-ink lg:text-4xl">
            {offer ? "Beim nächsten Mal ohne Mail." : "Dein Passwort."}
          </h1>
          <p className="max-w-xl text-base leading-relaxed text-muted">
            {offer
              ? "Leg ein Passwort fest, dann meldest du dich mit Mailadresse und Passwort an. Der Anmeldelink bleibt als zweiter Weg."
              : "Mit dem neuen Passwort meldest du dich im Web und in der App an. Der Anmeldelink bleibt als zweiter Weg."}
          </p>
        </div>
      </section>

      <section className="flex flex-col justify-start gap-6 border-t border-white/5 bg-panel px-6 py-12 lg:justify-center lg:border-l lg:border-t-0 lg:px-12">
        <div className="flex w-full max-w-md flex-col gap-6">
          <div className="flex flex-col gap-2">
            <h2 className="text-xl font-bold text-ink">
              {hasPassword ? "Neues Passwort festlegen" : "Passwort festlegen"}
            </h2>
            <p className="text-sm text-muted">
              Für <span className="text-ink">{data.user.email}</span>
            </p>
          </div>
          <PasswordForm email={data.user.email ?? ""} next={next} />
          <Link
            href={leavePath}
            className="flex h-12 items-center self-start rounded-md text-sm font-bold text-signal underline-offset-4 hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
          >
            {offer ? "Später festlegen" : "Abbrechen"}
          </Link>
        </div>
      </section>
    </main>
  );
}
