// Team Performance OS — Team-Tagesübersicht LoadDeviation (Modul 5, Bridge
// Punkt 77). Ruft public.rpc_get_deviations_today() mit dem JWT der angemeldeten
// Person auf. Die Tür ist SECURITY INVOKER und reicht an app.rpc_get_deviations_
// today() durch (Muster D): Staff bekommt nur state=released ohne pain_max,
// Medizin bekommt alles — die Filterung passiert in der Tür, nicht hier.
//
// Getrennt von lib/trainer/api.ts (fetchKaderForCoach): dasselbe Prinzip wie bei
// der Medizinsicht (lib/medical/api.ts, fetchPersonDeviations) — MODULE_DISABLED
// ist eine eigene, ruhige Antwort, kein Fehler, der die Kaderliste mitreißt.
//
// Kein stiller Fallback: jeder Fehler wird geworfen (SESSION-BRIDGE Regel 2).

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { KaderAccessError, classifyRpcError } from "./errors";
import type { DeviationMetric, DeviationState } from "@/lib/medical/types";
import type { KaderMember, Player } from "./types";

export { KaderAccessError, classifyRpcError } from "./errors";

// public.rpc_get_deviations_today — Feldnamen wie die Tür sie liefert
// (backend/35_load_deviation.sql, Abschnitt 10). Schmaleres Feld-Set als
// rpc_get_person_deviations: kein detected_on, kein z_mean_7/trend_slope_7,
// kein reviewed_by/reviewed_at (Team-weite Tagesliste, keine Einzelakte).
export type DeviationsTodayRow = {
  id: string;
  metric: DeviationMetric;
  deviation_pct: number;
  state: DeviationState;
  magnitude: number | null;
  streak_days: number | null;
  days_out_7: number | null;
  statement_key: string | null;
};

export type DeviationsTodayEntry = {
  person_id: string;
  deviations: DeviationsTodayRow[];
};

export async function fetchDeviationsToday(
  date?: string,
): Promise<DeviationsTodayEntry[]> {
  const supabase = createSupabaseServerClient();

  // Serverseitig gegen den Auth-Server geprueft, kein Aufruf ohne Login.
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError?.name === "AuthRetryableFetchError") {
    throw new KaderAccessError("Auth-Server nicht erreichbar.", "NETWORK");
  }
  if (userError || !user) {
    throw new KaderAccessError("Nicht angemeldet.", "UNAUTHENTICATED");
  }

  const { data, error, status } = await supabase.rpc(
    "rpc_get_deviations_today",
    date ? { p_date: date } : undefined,
  );

  if (error) {
    throw classifyRpcError(error, status);
  }
  if (!data) {
    throw new KaderAccessError("Antwort ist leer.", "RPC_FAILED", "empty_payload");
  }

  return Array.isArray(data) ? (data as DeviationsTodayEntry[]) : [];
}

// Eine Gruppe: eine Person aus dem Kader plus ihre heutigen Abweichungen.
export type DeviationTeamGroup = {
  player: Player;
  deviations: DeviationsTodayRow[];
};

const UNKNOWN_PLAYER = (personId: string): Player => ({
  id: personId,
  jersey: 0,
  name: "Unbekannte Person",
  position: "",
});

// Reine Funktion (kein Next/Supabase-Import), damit sie ohne Server-Kontext
// testbar ist (wie attentionSort in sort.ts). Verknuepft die Tagesliste mit dem
// Kader-Roster fuer Name/Rueckennummer/Position (die Tuer liefert nur person_id,
// Modul-Spec Abschnitt 5) und sortiert nach Anzahl der Abweichungen absteigend —
// eine Zaehlung, keine verdichtete Risikozahl (MDR-Regel 2 verbietet genau das).
// Bei gleicher Anzahl entscheidet die Rueckennummer, wie ueberall im Kader.
export function buildDeviationTeamGroups(
  entries: DeviationsTodayEntry[],
  roster: KaderMember[],
): DeviationTeamGroup[] {
  const players = new Map(roster.map((m) => [m.player.id, m.player]));

  const groups = entries
    .filter((entry) => entry.deviations.length > 0)
    .map((entry) => ({
      player: players.get(entry.person_id) ?? UNKNOWN_PLAYER(entry.person_id),
      deviations: entry.deviations,
    }));

  return groups.sort((a, b) => {
    if (b.deviations.length !== a.deviations.length) {
      return b.deviations.length - a.deviations.length;
    }
    return a.player.jersey - b.player.jersey;
  });
}
