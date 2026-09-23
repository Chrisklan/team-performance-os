// Team Performance OS — Daten-Layer der Medizinsicht (Web Vorlauf, Bridge Punkt 33).
//
// Nur Server (next/headers ueber createSupabaseServerClient). Jeder Aufruf laeuft mit dem JWT der angemeldeten Person gegen eine
// Tuer in public (SECURITY INVOKER). Der Waechter sitzt in der Datenbank, diese
// Datei prueft die Rolle nur vorher, damit ein Trainer die Seite gar nicht erst
// bekommt und keine Medizin-Tuer aufruft (jede Ablehnung ist eine Zeile in
// app.access_denials, und die soll Missbrauch zeigen, nicht Navigation).
//
// Protokoll: rpc_list_team_members schreibt keine Zeile. Das Oeffnen einer Person
// ruft vier Tueren je einmal auf, jede schreibt genau eine Zeile in app.access_log
// mit subject_id = diese Person. Das ist "ein Aufruf je Oeffnen" aus Modul Body-Map
// 7.3, je Tuer. Kein Zwischenspeicher: kein unstable_cache, kein fetch Cache, die
// Seiten sind dynamisch und der Browser bekommt no-store (next.config.mjs).
//
// Kein stiller Fallback: jeder Fehler wird geworfen (SESSION-BRIDGE Regel 2).

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { KaderAccessError, classifyRpcError } from "@/lib/trainer/errors";
import { appRoleFromClaims, isMedicalRole, type MedicalRole } from "./role";
import type {
  CheckinsPayload,
  ClearancePayload,
  PersonDetail,
  ReadinessPayload,
  RegionReportsPayload,
  TeamMember,
  TeamMembersPayload,
} from "./types";

export { KaderAccessError as MedicalAccessError } from "@/lib/trainer/errors";

type ServerClient = ReturnType<typeof createSupabaseServerClient>;

// Rolle serverseitig aus dem signaturgeprueften JWT. Wirft UNAUTHENTICATED ohne
// Sitzung und FORBIDDEN fuer jede Rolle ausser physio und doctor.
export async function requireMedicalSession(): Promise<{
  supabase: ServerClient;
  role: MedicalRole;
}> {
  const supabase = createSupabaseServerClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error?.name === "AuthRetryableFetchError") {
    throw new KaderAccessError("Auth-Server nicht erreichbar.", "NETWORK");
  }
  if (error || !data?.claims) {
    throw new KaderAccessError("Nicht angemeldet.", "UNAUTHENTICATED");
  }
  const role = appRoleFromClaims(data.claims);
  if (!isMedicalRole(role)) {
    throw new KaderAccessError("Nur für Physio und Arzt.", "FORBIDDEN", "role");
  }
  return { supabase, role };
}

async function callDoor<T>(
  supabase: ServerClient,
  fn: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const { data, error, status } = await supabase.rpc(fn, args);
  if (error) throw classifyRpcError(error, status);
  if (!data) throw new KaderAccessError("Leere Antwort.", "RPC_FAILED", "empty_payload");
  return data as T;
}

export async function fetchTeamMembers(supabase: ServerClient): Promise<TeamMember[]> {
  const payload = await callDoor<TeamMembersPayload>(supabase, "rpc_list_team_members");
  return Array.isArray(payload.members) ? payload.members : [];
}

export const REPORT_DAYS = 28;

// Erst die Regionen: ihre Tuer rechnet den Zeitraum in der Zeitzone des Teams.
// Check-ins und Readiness laufen dann ueber genau diesen Zeitraum, nicht ueber die
// ganze Historie (so wenig Art. 9 Daten wie noetig).
export async function fetchPersonDetail(
  supabase: ServerClient,
  personId: string,
): Promise<PersonDetail> {
  const regions = await callDoor<RegionReportsPayload>(
    supabase,
    "rpc_body_map_region_reports",
    { p_person_id: personId, p_days: REPORT_DAYS },
  );
  const range = { p_person_id: personId, p_from: regions.from, p_to: regions.to };
  const [checkins, readiness, clearance] = await Promise.all([
    callDoor<CheckinsPayload>(supabase, "rpc_medical_checkins", range),
    callDoor<ReadinessPayload>(supabase, "rpc_medical_readiness", range),
    callDoor<ClearancePayload>(supabase, "rpc_get_clearance", { p_person_id: personId }),
  ]);
  return { regions, checkins, readiness, clearance };
}
