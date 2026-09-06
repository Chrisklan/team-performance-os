// Team Performance OS — Supabase-Client (Server-seitig).
// Pilot-Stand: kein echtes Auth/JWT-Wiring (Follow-up-Task). jwtToken ist optional
// und wird als Bearer-Header mitgegeben, bis Next.js-Server-Auth angebunden ist.
// Hinweis: supabase.auth.setAuth() existiert in der installierten auth-js-Version
// nicht mehr — der Bearer-Header auf dem Client ist der aktuelle Ersatz dafuer.

import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

export function createServerClient(jwtToken?: string) {
  return createClient(supabaseUrl, supabaseAnonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
    global: jwtToken
      ? { headers: { Authorization: `Bearer ${jwtToken}` } }
      : undefined,
  });
}
