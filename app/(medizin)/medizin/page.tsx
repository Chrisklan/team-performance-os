// Team Performance OS — Medizinsicht, Kaderliste ohne Auswahl (Web Vorlauf, Bridge Punkt 33).
//
// Server Component, nur fuer physio und doctor (Rolle aus dem JWT, serverseitig).
// Ruft genau eine Tuer: public.rpc_list_team_members. Keine Gesundheitsdaten auf
// dieser Seite ausser dem Freigabestatus, den auch das Trainerteam sieht.

import { MedicalShell } from "@/components/medical/MedicalShell";
import { MedicalStateScreen } from "@/components/medical/MedicalStateScreen";
import { ModuleFlagPanel } from "@/components/medical/ModuleFlagPanel";
import {
  MedicalAccessError,
  fetchModuleFlag,
  fetchTeamMembers,
  requireMedicalSession,
} from "@/lib/medical/api";
import { LOAD_DEVIATION_FLAG } from "@/lib/medical/types";

// Jede Anfrage neu, nichts aus einem Zwischenspeicher.
export const metadata = { title: "Medizin · Kaderliste · Team Performance OS" };

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function MedizinPage() {
  try {
    const { supabase, role } = await requireMedicalSession();
    const members = await fetchTeamMembers(supabase);
    // ModuleFlagPanel ist nur Arzt vorbehalten (Modul-LoadDeviation.md Abschnitt 6),
    // die Tuer selbst lehnt physio ohnehin ab -- der Aufruf entfaellt fuer physio ganz.
    const moduleFlagEnabled =
      role === "doctor" ? await fetchModuleFlag(supabase, LOAD_DEVIATION_FLAG) : null;
    return (
      <MedicalShell
        role={role}
        members={members}
        topPanel={
          moduleFlagEnabled !== null ? <ModuleFlagPanel initialEnabled={moduleFlagEnabled} /> : undefined
        }
      >
        <section className="flex max-w-xl flex-col gap-4">
          <h1 className="font-display text-xl font-bold uppercase leading-tight text-ink">
            Spielerin wählen
          </h1>
          <p className="text-base leading-relaxed text-muted">
            Links steht der Kader. Wähle eine Spielerin, um ihre Meldungen je Region, ihre Check-ins,
            ihre Readiness und ihre Freigabe der letzten 28 Tage zu sehen.
          </p>
          <p className="text-sm leading-relaxed text-muted">
            Jedes Öffnen einer Spielerin wird protokolliert und erscheint in ihrer Zugriffsübersicht.
          </p>
        </section>
      </MedicalShell>
    );
  } catch (error) {
    if (error instanceof MedicalAccessError) {
      return (
        <MedicalStateScreen
          kind={error.code}
          detail={error.code === "RPC_FAILED" ? error.detail : undefined}
        />
      );
    }
    throw error;
  }
}
