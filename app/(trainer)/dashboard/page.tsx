// Team Performance OS — Trainer-Dashboard (Morning Ops).
// Server Component: holt den Post-RLS-Kader-Payload, sortiert Attention-first
// und rendert Header + KaderGrid. Interaktive Teile (Filter/Drawer) liegen im
// Client-Component-Baum von KaderGrid.

import { KaderGrid } from "@/components/trainer/KaderGrid";
import { fetchKaderForCoach } from "@/lib/trainer/api";
import { attentionSort } from "@/lib/trainer/sort";

export default async function TrainerDashboardPage() {
  const payload = await fetchKaderForCoach();
  const members = attentionSort(payload.members);
  const isLive = payload.syncState === "live";

  return (
    <main className="mx-auto flex max-w-7xl flex-col gap-8 px-8 py-12">
      <header className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-bold text-ink">
          Trainer-Dashboard · {payload.asOf} · {payload.kaderName}
        </h1>
        <span className="flex items-center gap-2 text-sm text-muted">
          <span
            aria-hidden="true"
            className={`h-2 w-2 rounded-full ${isLive ? "bg-ok" : "bg-muted"}`}
          />
          {isLive ? "Live" : "Letzter Sync"}
        </span>
      </header>

      <KaderGrid members={members} />
    </main>
  );
}
