// Team Performance OS — Planung und Pruefung Plan gegen Zustand (AP-69).
//
// Server Component. Rollen (aus dem JWT, die Tueren pruefen dieselbe Regel ein
// zweites Mal):
//   * coach/athletic_coach: Einheiten planen (AP-68 Tueren), Pruefung Regel v1,
//     Hinweise wegklicken, KI Zuordnung pruefen, wenn Team-Schalter UND
//     Betreiber-Notaus an sind und die Einheit gespeichert ist.
//   * admin: nur der Team-Schalter fuer die KI Zuordnung (AiSwitchPanel). Admin
//     ist kein Staff, die Planungs- und Pruef-Tueren lehnen admin ab, deshalb
//     rendert die Seite fuer admin kein Formular.
//   * physio/doctor: eigene Sicht unter /medizin.
//   * player: kein Zugriff.
// Aufrufe nur mit dem JWT der angemeldeten Person, nie service_role.

import Link from "next/link";
import { redirect } from "next/navigation";
import { KaderStateScreen } from "@/components/trainer/KaderStateScreen";
import { SignOutButton } from "@/components/trainer/SignOutButton";
import { PasswordLink } from "@/components/account/PasswordLink";
import { AiSwitchPanel } from "@/components/planung/AiSwitchPanel";
import { PlanungWorkspace } from "@/components/planung/PlanungWorkspace";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { appRoleFromClaims, isMedicalRole, isUuid } from "@/lib/medical/role";
import { classifyRpcError } from "@/lib/trainer/errors";
import { readJevConfig } from "@/lib/ai/jev";
import {
  JEV_SQUAD_CHECK_FLAG,
  type SquadCheckPayload,
  type TrainingSession,
} from "@/lib/planung/types";

export const metadata = { title: "Planung · Team Performance OS" };
export const dynamic = "force-dynamic";
export const revalidate = 0;

const STAFF_ROLES = new Set(["coach", "athletic_coach"]);

function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function Header({ title }: { title: string }) {
  return (
    <header className="flex flex-wrap items-center justify-between gap-4">
      <div className="flex flex-col gap-1">
        <Link
          href="/dashboard"
          className="flex h-12 items-center text-sm text-muted transition-colors hover:text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-signal"
        >
          ← Zum Kader
        </Link>
        <h1 className="text-2xl font-bold text-ink">{title}</h1>
      </div>
      <div className="flex items-center gap-4">
        <PasswordLink />
        <SignOutButton />
      </div>
    </header>
  );
}

export default async function PlanungPage({
  searchParams,
}: {
  searchParams: { session?: string | string[] };
}) {
  const supabase = createSupabaseServerClient();
  const { data: claimData } = await supabase.auth.getClaims();
  const role = appRoleFromClaims(claimData?.claims);
  if (isMedicalRole(role)) redirect("/medizin");

  if (role === "admin") {
    const { data, error, status } = await supabase.rpc("rpc_get_module_flag", { p_flag: JEV_SQUAD_CHECK_FLAG });
    if (error) {
      const classified = classifyRpcError(error, status);
      return <KaderStateScreen kind={classified.code} detail={classified.code === "RPC_FAILED" ? classified.detail : undefined} />;
    }
    return (
      <main className="mx-auto flex max-w-7xl flex-col gap-12 px-8 py-12">
        <Header title="Planung · Einstellungen" />
        <AiSwitchPanel initialEnabled={data === true} />
        <p className="max-w-prose text-sm leading-relaxed text-muted">
          Einheiten planen und prüfen kann nur das Trainerteam. Der Schalter gilt für das ganze Team und wirkt erst,
          wenn der Betreiber die KI Zuordnung zusätzlich freigegeben hat.
        </p>
      </main>
    );
  }

  if (!role || !STAFF_ROLES.has(role)) {
    return <KaderStateScreen kind="FORBIDDEN" />;
  }

  const today = new Date();
  const from = new Date(today);
  from.setUTCDate(from.getUTCDate() - 7);
  const to = new Date(today);
  to.setUTCDate(to.getUTCDate() + 21);

  const [{ data: listData, error: listError, status: listStatus }, { data: flagData, error: flagError }] =
    await Promise.all([
      supabase.rpc("rpc_list_training_sessions", { p_from: isoDate(from), p_to: isoDate(to) }),
      supabase.rpc("rpc_get_module_flag", { p_flag: JEV_SQUAD_CHECK_FLAG }),
    ]);

  if (listError) {
    const classified = classifyRpcError(listError, listStatus);
    return <KaderStateScreen kind={classified.code} detail={classified.code === "RPC_FAILED" ? classified.detail : undefined} />;
  }

  const sessions = (Array.isArray(listData) ? listData : []) as TrainingSession[];
  const rawParam = Array.isArray(searchParams.session) ? searchParams.session[0] : searchParams.session;
  const selected = rawParam && isUuid(rawParam) ? sessions.find((s) => s.id === rawParam) ?? null : null;

  // Die Pruefung einer gespeicherten Einheit laeuft schon beim Laden, mit den
  // gespeicherten Werten (Selbstausschluss aus der Tagessumme, Wegklicks).
  let initialCheck: SquadCheckPayload | null = null;
  let initialCheckError: string | null = null;
  if (selected && selected.planned_intensity !== null) {
    const { data, error, status } = await supabase.rpc("rpc_get_session_squad_check", {
      p_session_date: selected.session_date,
      p_duration_min: selected.duration_min,
      p_planned_intensity: selected.planned_intensity,
      p_session_id: selected.id,
    });
    if (error) initialCheckError = classifyRpcError(error, status).message;
    else initialCheck = data as SquadCheckPayload;
  } else if (selected) {
    initialCheckError = "Für diese Einheit ist keine Intensität geplant. Intensität eintragen und speichern.";
  }

  // KI Zuordnung nur, wenn Team-Schalter und Betreiber-Notaus beide an sind. Nur
  // ein Wahrheitswert geht an den Client, nie ein Key oder eine Konfiguration.
  const jevAvailable = !flagError && flagData === true && readJevConfig().enabled;

  return (
    <main className="mx-auto flex max-w-7xl flex-col gap-12 px-8 py-12">
      <Header title="Planung · Plan gegen Zustand" />

      <nav aria-label="Geplante Einheiten" className="flex flex-col gap-2">
        <p className="text-xs font-bold uppercase tracking-wide text-muted">Einheiten von {isoDate(from)} bis {isoDate(to)}</p>
        <ul className="flex flex-wrap gap-2">
          <li>
            <Link
              href="/planung"
              className={`flex h-12 items-center rounded-md border px-4 text-sm transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-signal ${
                selected ? "border-muted text-muted hover:text-ink" : "border-signal text-ink"
              }`}
            >
              Neue Einheit
            </Link>
          </li>
          {sessions.map((s) => (
            <li key={s.id}>
              <Link
                href={`/planung?session=${s.id}`}
                aria-current={selected?.id === s.id ? "page" : undefined}
                className={`flex h-12 items-center rounded-md border px-4 text-sm transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-signal ${
                  selected?.id === s.id ? "border-signal text-ink" : "border-muted text-muted hover:text-ink"
                }`}
              >
                {s.session_date}
                {s.start_time ? ` ${s.start_time.slice(0, 5)}` : ""} · {s.duration_min} min
              </Link>
            </li>
          ))}
        </ul>
      </nav>

      <PlanungWorkspace
        key={selected?.id ?? "new"}
        initialSession={selected}
        initialCheck={initialCheck}
        initialCheckError={initialCheckError}
        defaultDate={isoDate(today)}
        jevAvailable={jevAvailable}
      />
    </main>
  );
}
