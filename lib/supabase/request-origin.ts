// Team Performance OS — Origin der laufenden Anfrage (fuer emailRedirectTo).
// Hinter Vercel liefert x-forwarded-host/-proto die oeffentliche Adresse.

import { headers } from "next/headers";

export function requestOrigin(): string {
  const h = headers();
  const host = h.get("x-forwarded-host") ?? h.get("host") ?? "localhost:3000";
  const isLocal = host.startsWith("localhost") || host.startsWith("127.0.0.1");
  const proto = h.get("x-forwarded-proto") ?? (isLocal ? "http" : "https");
  return `${proto}://${host}`;
}
