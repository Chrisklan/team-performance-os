// Team Performance OS — Supabase-Client im Browser, nur fuer die Anmeldung mit Passwort.
// Warum im Browser und nicht als Server Action: GoTrue begrenzt Passwortversuche je
// IP-Adresse. Liefe die Anmeldung ueber den Server, saehe GoTrue fuer alle Nutzer
// dieselbe Server-IP. Ein Angreifer koennte dann alle aussperren und wuerde selbst
// nie gebremst. Aus dem Browser zaehlt die IP der Person, die es versucht.
// @supabase/ssr legt die Session in Cookies ab, die Middleware liest sie wie gewohnt.

import { createBrowserClient } from "@supabase/ssr";

export function createSupabaseBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("Supabase-Env fehlt: NEXT_PUBLIC_SUPABASE_URL und NEXT_PUBLIC_SUPABASE_ANON_KEY.");
  }
  return createBrowserClient(url, anonKey);
}
