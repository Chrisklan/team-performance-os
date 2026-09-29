// Team Performance OS — Pseudonymisierung der Trainer-Frage (AP-70b). Rein,
// ohne Next/Supabase-Importe. Laeuft VOR jedem Modellaufruf: ersetzt jeden
// Spielernamen und jede Rueckennummer, die in der Trainer-Frage vorkommt,
// deterministisch durch einen P-Ref-Platzhalter (P01, P02, ...). Das Modell
// sieht danach nur noch Platzhalter, nie einen echten Namen oder eine echte
// Rueckennummer.
//
// Eingabe ist der Tuer-Payload von public.rpc_trainer_morning_ops (CoachKaderPayload,
// lib/trainer/types.ts) -- dieselbe Quelle, die queryActions.ts ohnehin fuer die
// deterministische Auswertung (evaluate.ts) liest.

import type { CoachKaderPayload, KaderMember } from "@/lib/trainer/types";

export type ResolvedPlayerRef = {
  ref: string;
  personId: string;
  name: string;
  jersey: number;
  position: string;
  band: KaderMember["readiness"]["band"];
  medicalClearance: KaderMember["medicalClearance"];
  hasCheckIn: boolean;
};

export type ResolveResult = {
  pseudonymizedQuestion: string;
  refs: ResolvedPlayerRef[];
  // Nur die Refs, die tatsaechlich in der Frage namentlich vorkamen (fuer
  // subject_ids der Tuer -- Team-Zugehoerigkeits-Pruefung, siehe queryActions.ts).
  mentionedRefs: ResolvedPlayerRef[];
};

function refWidth(total: number): number {
  return Math.max(2, String(total).length);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Sortiert absteigend nach Laenge, damit ein laengerer Name (z.B. "Max Mustermann")
// vor einem kuerzeren Teiltreffer (z.B. "Max") ersetzt wird.
function byDescendingLength(a: string, b: string): number {
  return b.length - a.length;
}

export function buildPlayerRefs(payload: CoachKaderPayload): ResolvedPlayerRef[] {
  const width = refWidth(payload.members.length);
  return payload.members.map((m, i) => ({
    ref: "P" + String(i + 1).padStart(width, "0"),
    personId: m.player.id,
    name: m.player.name,
    jersey: m.player.jersey,
    position: m.player.position,
    band: m.readiness.band,
    medicalClearance: m.medicalClearance,
    hasCheckIn: m.hasCheckIn,
  }));
}

// Ersetzt jeden Namen (exakter, case-insensitiver Teilstring-Treffer, laengster
// Name zuerst) und jede Rueckennummer (als abgegrenztes Zahl-Token, z.B. "Nr. 11",
// "#11", "11") durch den jeweiligen P-Ref. Deterministisch, kein Modellaufruf.
export function resolvePlayerRefs(question: string, payload: CoachKaderPayload): ResolveResult {
  const refs = buildPlayerRefs(payload);
  let pseudonymized = question;
  const mentioned = new Set<string>();

  const byName = [...refs].sort((a, b) => byDescendingLength(a.name, b.name));
  for (const r of byName) {
    if (!r.name.trim()) continue;
    const pattern = new RegExp(escapeRegExp(r.name), "gi");
    if (pattern.test(pseudonymized)) {
      mentioned.add(r.ref);
      pseudonymized = pseudonymized.replace(pattern, r.ref);
    }
  }

  const byJersey = [...refs].filter((r) => r.jersey > 0);
  for (const r of byJersey) {
    // Zahl als eigenes Token (nicht Teil einer laengeren Zahl), optional mit
    // "#" oder "Nr."/"nr" davor.
    const pattern = new RegExp(`(?:#|\\bnr\\.?\\s*)?\\b${r.jersey}\\b`, "gi");
    if (pattern.test(pseudonymized)) {
      mentioned.add(r.ref);
      pseudonymized = pseudonymized.replace(pattern, r.ref);
    }
  }

  return {
    pseudonymizedQuestion: pseudonymized,
    refs,
    mentionedRefs: refs.filter((r) => mentioned.has(r.ref)),
  };
}
