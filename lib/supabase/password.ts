// Team Performance OS — Regeln fuer das eigene Passwort (rein, ohne Next/Supabase-Importe).
//
// Dieselbe Mindestlaenge steht in der Supabase-Auth-Konfiguration (password_min_length).
// Die Pruefung hier ist nur fuer eine verstaendliche Meldung vor dem Absenden, die
// verbindliche Pruefung macht GoTrue.
// Obergrenze 72 Bytes: GoTrue speichert bcrypt, alles danach wuerde still abgeschnitten.

export const PASSWORD_MIN_LENGTH = 10;
export const PASSWORD_MAX_BYTES = 72;

// Merker in user_metadata: das Konto hat ein selbst gesetztes Passwort. Nur ein Hinweis
// fuer die Oberflaeche (Angebot nach dem Anmeldelink), keine Sicherheitsentscheidung,
// denn user_metadata kann der Nutzer selbst schreiben.
export const PASSWORD_SET_FLAG = "password_set";

export type PasswordProblem = "too_short" | "too_long" | "mismatch";

export function passwordProblem(password: string, confirm: string): PasswordProblem | null {
  if (password.length < PASSWORD_MIN_LENGTH) return "too_short";
  if (new TextEncoder().encode(password).length > PASSWORD_MAX_BYTES) return "too_long";
  if (password !== confirm) return "mismatch";
  return null;
}

export function hasOwnPassword(userMetadata: unknown): boolean {
  if (!userMetadata || typeof userMetadata !== "object") return false;
  return (userMetadata as Record<string, unknown>)[PASSWORD_SET_FLAG] === true;
}
