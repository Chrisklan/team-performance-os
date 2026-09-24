// Team Performance OS — Auth-Callback fuer Magic-Links.
// Zwei Wege:
//  * ?code=...            PKCE, Standard von signInWithOtp (Verifier-Cookie im selben Browser)
//  * ?token_hash=&type=   Mail-Vorlage mit Token-Hash oder Test per generate_link
// Erfolg: Session-Cookies gesetzt, weiter auf "next" (nur interne Pfade). Hat das Konto
// noch kein eigenes Passwort, kommt vorher das Angebot auf /konto/passwort (ueberspringbar).
// Fehler: zurueck auf /login mit Hinweis, kein Detail aus GoTrue nach aussen.

import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/supabase/auth-redirect";
import { hasOwnPassword } from "@/lib/supabase/password";

const PASSWORD_PAGE = "/konto/passwort";

const OTP_TYPES: readonly EmailOtpType[] = [
  "magiclink",
  "email",
  "signup",
  "recovery",
  "invite",
  "email_change",
];

export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;
  const next = safeNextPath(searchParams.get("next"));
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;

  const supabase = createSupabaseServerClient();
  let failed = true;

  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    failed = Boolean(error);
  } else if (tokenHash && type && OTP_TYPES.includes(type)) {
    const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });
    failed = Boolean(error);
  }

  if (failed) {
    const loginUrl = new URL("/login", origin);
    loginUrl.searchParams.set("error", "callback");
    loginUrl.searchParams.set("next", next);
    return NextResponse.redirect(loginUrl);
  }

  if (next !== PASSWORD_PAGE) {
    const { data } = await supabase.auth.getUser();
    if (data.user && !hasOwnPassword(data.user.user_metadata)) {
      const offerUrl = new URL(PASSWORD_PAGE, origin);
      offerUrl.searchParams.set("next", next);
      return NextResponse.redirect(offerUrl);
    }
  }
  return NextResponse.redirect(new URL(next, origin));
}
