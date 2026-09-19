// Team Performance OS — Supabase-Env (Web).
// Nur URL und Anon- bzw. Publishable-Key. Kein Service-Role-Key im Web-Code.
// Fehlt ein Wert, bricht der Aufruf mit klarer Meldung ab statt still weiterzulaufen.

export function supabaseEnv(): { url: string; anonKey: string } {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error(
      "Supabase-Env fehlt: NEXT_PUBLIC_SUPABASE_URL und NEXT_PUBLIC_SUPABASE_ANON_KEY in .env.local setzen (Vorlage .env.example).",
    );
  }
  return { url, anonKey };
}
