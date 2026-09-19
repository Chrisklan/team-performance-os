// Team Performance OS — Redirect-Hilfen fuer Login und Callback.
// "next" kommt aus der URL und ist damit Fremdeingabe: nur interne Pfade zulassen,
// sonst wuerde /auth/callback zum Open Redirect.

const DEFAULT_NEXT = "/dashboard";

export function safeNextPath(raw: string | null | undefined): string {
  if (!raw) return DEFAULT_NEXT;
  // Nur absolute interne Pfade: "/x", nie "//host", "/\host" oder "https://...".
  if (!raw.startsWith("/") || raw.startsWith("//") || raw.startsWith("/\\")) {
    return DEFAULT_NEXT;
  }
  // Kein Rueckweg in die Auth-Routen (Schleife).
  if (raw === "/login" || raw.startsWith("/login?") || raw.startsWith("/auth/")) {
    return DEFAULT_NEXT;
  }
  return raw;
}
