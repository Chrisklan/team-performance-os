// Team Performance OS — Rolle aus den JWT Claims (rein, ohne Next/Supabase-Importe).
//
// Die Rolle steht als Claim app_role im Access Token (Custom Access Token Hook,
// ADR-015). Gelesen wird sie serverseitig aus supabase.auth.getClaims(), das die
// Signatur prueft. Die Datenbank prueft dieselbe Rolle ein zweites Mal gegen
// role_assignments: diese Funktion entscheidet nur, welche Seite der Server
// ueberhaupt rendert und welche Tuer er ruft, nicht, was die Tuer herausgibt.

export const MEDICAL_ROLES = ["physio", "doctor"] as const;
export type MedicalRole = (typeof MEDICAL_ROLES)[number];

export function appRoleFromClaims(claims: unknown): string | null {
  if (!claims || typeof claims !== "object") return null;
  const role = (claims as Record<string, unknown>).app_role;
  return typeof role === "string" && role.length > 0 ? role : null;
}

export function isMedicalRole(role: string | null | undefined): role is MedicalRole {
  return role === "physio" || role === "doctor";
}

// Startseite je Rolle. Physio und Arzt landen in der Medizinsicht, alle anderen
// im Trainer-Dashboard, das fuer Nicht-Trainer seinen eigenen Zustand zeigt.
export function homePathForRole(role: string | null | undefined): "/medizin" | "/dashboard" {
  return isMedicalRole(role) ? "/medizin" : "/dashboard";
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Eine Person-ID aus der URL ist Fremdeingabe. Was keine UUID ist, geht nicht an
// die Tuer: kein Aufruf, keine Ablehnungszeile fuer Tippfehler.
export function isUuid(raw: string): boolean {
  return UUID.test(raw);
}
