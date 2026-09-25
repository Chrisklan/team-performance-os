// Team Performance OS — Team-Tagesübersicht LoadDeviation (Modul 5, Bridge
// Punkt 77, Design-Codex-Paket). Server Component: holt Kader-Roster (für Name/
// Rückennummer) und die heutige Abweichungsliste getrennt, rendert eine
// redaktionelle Liste statt eines Kartenrasters (Design-Codex Schritt 1b).
//
// MODULE_DISABLED ist kein Fehler, sondern eine noch nicht getroffene
// Entscheidung des Arztes (Modul-LoadDeviation.md Abschnitt 7) — eigener
// ruhiger Zustand, KaderStateScreen kennt ihn bereits (Bridge Punkt 57 Teil 3
// Folgepaket, gebaut fuer die Medizinsicht, hier wiederverwendet).

import Link from "next/link";
import { redirect } from "next/navigation";
import { KaderStateScreen } from "@/components/trainer/KaderStateScreen";
import { DeviationsTodayList } from "@/components/trainer/DeviationsTodayList";
import { DisclaimerBar } from "@/components/medical/DisclaimerBar";
import { SignOutButton } from "@/components/trainer/SignOutButton";
import { PasswordLink } from "@/components/account/PasswordLink";
import { KaderAccessError, fetchKaderForCoach } from "@/lib/trainer/api";
import { fetchDeviationsToday, buildDeviationTeamGroups } from "@/lib/trainer/deviations";
import type { CoachKaderPayload } from "@/lib/trainer/types";
import type { DeviationsTodayEntry } from "@/lib/trainer/deviations";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { appRoleFromClaims, isMedicalRole } from "@/lib/medical/role";

export const metadata = { title: "Abweichungen heute · Team Performance OS" };

export default async function DeviationsTodayPage() {
  // Physio und Arzt haben ihre eigene Sicht, dieselbe Weiche wie /dashboard.
  const { data: claimData } = await createSupabaseServerClient().auth.getClaims();
  if (isMedicalRole(appRoleFromClaims(claimData?.claims))) redirect("/medizin");

  let payload: CoachKaderPayload;
  try {
    payload = await fetchKaderForCoach();
  } catch (error) {
    if (error instanceof KaderAccessError) {
      return (
        <KaderStateScreen
          kind={error.code}
          detail={error.code === "RPC_FAILED" ? error.detail : undefined}
        />
      );
    }
    throw error; // unerwartet: app/(trainer)/error.tsx
  }

  let entries: DeviationsTodayEntry[];
  try {
    entries = await fetchDeviationsToday();
  } catch (error) {
    if (error instanceof KaderAccessError) {
      return (
        <KaderStateScreen
          kind={error.code}
          detail={error.code === "RPC_FAILED" ? error.detail : undefined}
        />
      );
    }
    throw error;
  }

  const groups = buildDeviationTeamGroups(entries, payload.members);

  return (
    <main className="mx-auto flex max-w-7xl flex-col gap-8 px-8 py-12">
      <header className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex flex-col gap-1">
          <Link
            href="/dashboard"
            className="flex h-12 items-center text-sm text-muted transition-colors hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
          >
            ← Zum Kader
          </Link>
          <h1 className="text-2xl font-bold text-ink">
            Abweichungen heute · {payload.kaderName}
          </h1>
        </div>
        <div className="flex items-center gap-4">
          <PasswordLink />
          <SignOutButton />
        </div>
      </header>

      <DisclaimerBar />

      <DeviationsTodayList groups={groups} />
    </main>
  );
}
