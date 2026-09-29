// Team Performance OS — generische Wire-Typen fuer JEV-Aufrufe (AP-70a).
// Vorher an lib/planung gebunden (lib/planung/jevSquadCheck.ts), jetzt hier:
// lib/ai/jev.ts (Provider-Adapter) kennt nur noch diese generische Form, nicht
// mehr die AP-69-spezifischen Kandidatenfelder. lib/planung/jevSquadCheck.ts
// importiert die Typen von hier (Abhaengigkeitsrichtung gedreht gegenueber vorher).
//
// Rein, ohne Next/Supabase-Importe.

export type JevQuestion = {
  type: "choice";
  instructions: { question: string; inspect: string; focus: string };
  criteria: Record<string, { what: string; not_for: string }>;
};

// state.athletes bewusst generisch (Record<string, unknown>[]): der
// Provider-Adapter kennt die konkreten Domaenenfelder eines Zwecks nicht,
// die Domaene (z.B. lib/planung/jevSquadCheck.ts) liefert bereits geformte,
// gewhitelistete Objekte.
export type JevRequest = {
  state: {
    session: Record<string, unknown>;
    athletes: Record<string, unknown>[];
  };
  questions: Record<string, JevQuestion>;
};

export type JevAnswer = { choice: string; confidence: number };
export type JevResponseBody = { answers?: Record<string, unknown> };
