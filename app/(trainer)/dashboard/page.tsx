// Team Performance OS — Trainer-Dashboard (Morning Ops).
// Server Component: holt den Post-RLS-Kader-Payload, sortiert Attention-first
// und rendert Header + KaderGrid. Interaktive Teile (Filter/Drawer) liegen im
// Client-Component-Baum von KaderGrid.
// Fehler werden nicht durch Fixtures ersetzt: jeder Fall hat einen eigenen Zustand.

import { KaderGrid } from "@/components/trainer/KaderGrid";
import { KaderStateScreen } from "@/components/trainer/KaderStateScreen";
import { SignOutButton } from "@/components/trainer/SignOutButton";
import {
  KaderAccessError,
  fetchKaderForCoach,
} from "@/lib/trainer/api";
import type { CoachKaderPayload } from "@/lib/trainer/types";
import { attentionSort } from "@/lib/trainer/sort";

export default async function TrainerDashboardPage() {
  let payload: CoachKaderPayload;
  try {
    payload = await fetchKaderForCoach();
  } catch (error) {
    if (error instanceof KaderAccessError) {
      // Fehlercode nur bei RPC_FAILED: bei den anderen Faellen hilft er dem Trainer nicht.
      return (
        <KaderStateScreen
          kind={error.code}
          detail={error.code === "RPC_FAILED" ? error.detail : undefined}
        />
      );
    }
    throw error; // unerwartet: app/(trainer)/error.tsx
  }

  if (payload.members.length === 0) {
    return <KaderStateScreen kind="EMPTY" />;
  }

  const members = attentionSort(payload.members);
  const isLive = payload.syncState === "live";

  return (
    <main className="mx-auto flex max-w-7xl flex-col gap-8 px-8 py-12">
      <header className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-bold text-ink">
          Trainer-Dashboard · {payload.asOf} · {payload.kaderName}
        </h1>
        <div className="flex items-center gap-4">
          <span className="flex items-center gap-2 text-sm text-muted">
            {/* needs_decision an Chris (AP-54): "ok" hat in v1.0 keinen Anker, Wert aus v0.5 unveraendert. */}
            <span
              aria-hidden="true"
              className={`h-2 w-2 rounded-full ${isLive ? "bg-[#3FB87A]" : "bg-muted"}`}
            />
            {isLive ? "Live" : "Letzter Sync"}
          </span>
          <SignOutButton />
        </div>
      </header>

      <KaderGrid members={members} />
    </main>
  );
}
