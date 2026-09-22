// Team Performance OS — Attention-first Sortierung (Trainer-Frontend).
// Deterministisch: gleiche Eingabe -> gleiche Reihenfolge, unabhängig von der
// ursprünglichen Array-Reihenfolge. Rückennummer als stabile Sekundärsortierung.
//
// Seit dem 2026-09-22 (Befund N7) gibt es für Staff keinen Readiness-Zahlwert
// mehr, nur noch das Band. Die Sortierung läuft deshalb über Zustandsklassen
// statt über einen Vergleich von Zahlen. Weggefallen ist der frühere Eimer
// "Faktor-Auffälligkeit oder starker Baseline-Drop": beide Eingaben (factors
// und value) sind Medizin und self vorbehalten.

import type { KaderMember } from "./types";

// Priorität (aufsteigend = zuerst angezeigt):
// 0: Band niedrig, mit heutigem Check-in
// 1: medicalStatus != green
// 2: kein Check-in
// 3: Rest
function attentionBucket(member: KaderMember): number {
  if (member.hasCheckIn && member.readiness.band === "low") return 0;
  if (member.medicalStatus !== "green") return 1;
  if (!member.hasCheckIn) return 2;
  return 3;
}

export function attentionSort(members: KaderMember[]): KaderMember[] {
  return [...members].sort((a, b) => {
    const bucketA = attentionBucket(a);
    const bucketB = attentionBucket(b);
    if (bucketA !== bucketB) return bucketA - bucketB;
    return a.player.jersey - b.player.jersey;
  });
}
