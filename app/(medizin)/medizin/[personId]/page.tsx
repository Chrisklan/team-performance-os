// Team Performance OS — Medizinsicht, eine Spielerin (Web Vorlauf, Bridge Punkt 33).
//
// Server Component, nur fuer physio und doctor. Nur lesend: kein Setzen, kein
// Vorschlagen (AP-47). Ein Seitenaufruf ruft jede der vier Detail-Tueren genau
// einmal, jede schreibt eine Zeile in die Zugriffsuebersicht der Spielerin.
//
// Was die Tuer nicht liefert, zeigt die Seite nicht, und nichts davon wird
// zwischengespeichert: die Seite ist dynamisch, der Browser bekommt no-store, der
// Router haelt dynamische Seiten nicht vor (next.config.mjs, staleTimes.dynamic 0).

import { notFound } from "next/navigation";
import { CheckinTable } from "@/components/medical/CheckinTable";
import { ClearanceBlock } from "@/components/medical/ClearanceBlock";
import { DeviationSection } from "@/components/medical/DeviationSection";
import { MedicalShell } from "@/components/medical/MedicalShell";
import { MedicalStateScreen } from "@/components/medical/MedicalStateScreen";
import { ReadinessSection } from "@/components/medical/ReadinessSection";
import { RegionTally } from "@/components/medical/RegionTally";
import {
  MedicalAccessError,
  fetchPersonDetail,
  fetchPersonDeviations,
  fetchTeamMembers,
  requireMedicalSession,
} from "@/lib/medical/api";
import { isUuid } from "@/lib/medical/role";
import type { LoadDeviation, PersonDetail } from "@/lib/medical/types";

export const metadata = { title: "Medizin · Spielerin · Team Performance OS" };

export const dynamic = "force-dynamic";
export const revalidate = 0;

type PageProps = { params: { personId: string } };

export default async function MedizinPersonPage({ params }: PageProps) {
  // Keine UUID: kein Aufruf, keine Ablehnungszeile fuer einen Tippfehler.
  if (!isUuid(params.personId)) notFound();

  let session: Awaited<ReturnType<typeof requireMedicalSession>>;
  try {
    session = await requireMedicalSession();
  } catch (error) {
    if (error instanceof MedicalAccessError) return <MedicalStateScreen kind={error.code} />;
    throw error;
  }
  const { supabase, role } = session;

  let members;
  try {
    members = await fetchTeamMembers(supabase);
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

  const member = members.find((m) => m.id === params.personId);

  // Nicht in der Liste: die Detail-Tueren werden nicht gerufen. Sie wuerden
  // ablehnen, denn die Liste benutzt dasselbe Praedikat wie ihr Waechter
  // (32_team_members_door.sql). Ein Tippfehler in der Adresse ist kein Zugriffsversuch.
  if (!member) {
    return (
      <MedicalShell role={role} members={members} selectedId={params.personId}>
        <MedicalStateScreen kind="PERSON_NOT_FOUND" inline />
      </MedicalShell>
    );
  }

  let detail: PersonDetail;
  try {
    detail = await fetchPersonDetail(supabase, member.id);
  } catch (error) {
    if (error instanceof MedicalAccessError) {
      const kind =
        error.code === "FORBIDDEN"
          ? "PERSON_FORBIDDEN"
          : error.code === "NOT_FOUND"
            ? "PERSON_NOT_FOUND"
            : error.code;
      return (
        <MedicalShell role={role} members={members} selectedId={member.id}>
          <MedicalStateScreen
            kind={kind}
            detail={error.code === "RPC_FAILED" ? error.detail : undefined}
            inline
          />
        </MedicalShell>
      );
    }
    throw error;
  }

  // LoadDeviation getrennt von fetchPersonDetail: MODULE_DISABLED ist kein
  // Fehler der ganzen Seite, sondern ein eigener, ruhiger Zustand nur dieses
  // Abschnitts (Bridge Punkt 57 Teil 3).
  let deviations: LoadDeviation[] | null = null;
  let deviationsError: MedicalAccessError | null = null;
  try {
    deviations = await fetchPersonDeviations(supabase, member.id, detail.regions.from, detail.regions.to);
  } catch (error) {
    if (error instanceof MedicalAccessError) deviationsError = error;
    else throw error;
  }

  return (
    <MedicalShell role={role} members={members} selectedId={member.id}>
      <header className="flex flex-col gap-6 border-b-2 border-muted pb-6">
        <div className="flex flex-col gap-1">
          <h1 className="font-display text-xl font-bold uppercase leading-tight text-ink md:text-3xl">
            {member.display_name}
          </h1>
          {member.person_position ? (
            <p className="text-sm text-muted">{member.person_position}</p>
          ) : null}
        </div>
        <ClearanceBlock clearance={detail.clearance} />
      </header>

      <RegionTally report={detail.regions} checkins={detail.checkins.checkins} />

      <div className="flex flex-col gap-12 border-t-2 border-muted pt-8">
        <ReadinessSection readiness={detail.readiness} />
        <CheckinTable checkins={detail.checkins.checkins} regionLabels={detail.regions.regions} />
        <DeviationSection personId={member.id} deviations={deviations} error={deviationsError} />
      </div>

      <p className="text-xs text-muted">
        Dieses Öffnen steht in der Zugriffsübersicht der Spielerin.
      </p>
    </MedicalShell>
  );
}
