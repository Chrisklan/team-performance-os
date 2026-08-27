// Team Performance OS — Attention-first Sortierung (Trainer-Frontend).
// Deterministisch: gleiche Eingabe -> gleiche Reihenfolge, unabhängig von der
// ursprünglichen Array-Reihenfolge. Rückennummer als stabile Sekundärsortierung.

import { isAuffaellig } from "./aggregate";
import type { KaderMember } from "./types";

const LOW_READINESS_THRESHOLD = 60;

// Priorität (aufsteigend = zuerst angezeigt):
// 0: niedrigste Readiness (< Schwelle, mit heutigem Check-in)
// 1: medicalStatus != green
// 2: Auffälligkeits-Flag (Faktor-Auffälligkeit oder starker Baseline-Drop)
// 3: kein Check-in
// 4: Rest
function attentionBucket(member: KaderMember): number {
  if (
    member.hasCheckIn &&
    member.readiness.value !== null &&
    member.readiness.value < LOW_READINESS_THRESHOLD
  ) {
    return 0;
  }
  if (member.medicalStatus !== "green") return 1;
  if (isAuffaellig(member)) return 2;
  if (!member.hasCheckIn) return 3;
  return 4;
}

export function attentionSort(members: KaderMember[]): KaderMember[] {
  return [...members].sort((a, b) => {
    const bucketA = attentionBucket(a);
    const bucketB = attentionBucket(b);
    if (bucketA !== bucketB) return bucketA - bucketB;

    if (bucketA === 0) {
      const readinessA = a.readiness.value as number;
      const readinessB = b.readiness.value as number;
      if (readinessA !== readinessB) return readinessA - readinessB;
    }

    return a.player.jersey - b.player.jersey;
  });
}
