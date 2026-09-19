// Team Performance OS — Supabase-Client fuer Server Components und Route Handler.
// Session kommt aus den Auth-Cookies (@supabase/ssr). Jede Abfrage laeuft mit dem
// JWT des angemeldeten Users, nie als anon mit Sonderrechten.
// Server Components duerfen keine Cookies schreiben: der Token-Refresh passiert in
// middleware.ts, hier wird setAll deshalb nur versucht.

import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { supabaseEnv } from "./env";

export function createSupabaseServerClient() {
  const { url, anonKey } = supabaseEnv();
  const cookieStore = cookies();

  return createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options),
          );
        } catch {
          // Aufruf aus einer Server Component: Middleware erneuert die Session.
        }
      },
    },
  });
}
