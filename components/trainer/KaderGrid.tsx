"use client";

// Team Performance OS — KaderGrid.
// Grid großer PlayerCards inkl. Filter/Sort-Controls (Attention-first Default)
// und Client-State für den DetailDrawer.

import { useMemo, useState } from "react";
import { isAuffaellig } from "@/lib/trainer/aggregate";
import { attentionSort } from "@/lib/trainer/sort";
import type { KaderMember } from "@/lib/trainer/types";
import { DetailDrawer } from "./DetailDrawer";
import { PlayerCard } from "./PlayerCard";

type SortMode = "attention" | "jersey";

type KaderGridProps = {
  members: KaderMember[];
};

export function KaderGrid({ members }: KaderGridProps) {
  const [selected, setSelected] = useState<KaderMember | null>(null);
  const [sortMode, setSortMode] = useState<SortMode>("attention");
  const [onlyAuffaellig, setOnlyAuffaellig] = useState(false);

  const displayedMembers = useMemo(() => {
    const filtered = onlyAuffaellig
      ? members.filter((m) => isAuffaellig(m) || !m.hasCheckIn)
      : members;
    if (sortMode === "jersey") {
      return [...filtered].sort((a, b) => a.player.jersey - b.player.jersey);
    }
    return attentionSort(filtered);
  }, [members, sortMode, onlyAuffaellig]);

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center gap-4">
        <div className="flex gap-2" role="group" aria-label="Sortierung">
          <button
            type="button"
            onClick={() => setSortMode("attention")}
            aria-pressed={sortMode === "attention"}
            className={`rounded-sm px-3 py-2 text-sm font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-accent ${
              sortMode === "attention"
                ? "bg-accent text-surface"
                : "bg-white/5 text-muted hover:text-ink"
            }`}
          >
            Attention-first
          </button>
          <button
            type="button"
            onClick={() => setSortMode("jersey")}
            aria-pressed={sortMode === "jersey"}
            className={`rounded-sm px-3 py-2 text-sm font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-accent ${
              sortMode === "jersey"
                ? "bg-accent text-surface"
                : "bg-white/5 text-muted hover:text-ink"
            }`}
          >
            Rückennummer
          </button>
        </div>

        <label className="flex items-center gap-2 text-sm text-muted">
          <input
            type="checkbox"
            checked={onlyAuffaellig}
            onChange={(event) => setOnlyAuffaellig(event.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Nur Auffällige
        </label>
      </div>

      <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 xl:grid-cols-3">
        {displayedMembers.map((member) => (
          <PlayerCard key={member.player.id} member={member} onSelect={setSelected} />
        ))}
      </div>

      <DetailDrawer member={selected} onClose={() => setSelected(null)} />
    </div>
  );
}
