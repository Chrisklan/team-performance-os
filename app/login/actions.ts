"use server";

// Team Performance OS — Magic-Link anfordern (Server Action).
// signInWithOtp laeuft serverseitig, damit der PKCE-Verifier als Cookie im selben
// Browser liegt, der spaeter /auth/callback aufruft.
// shouldCreateUser=false: es entstehen keine Konten ueber dieses Formular.
// Unbekannte Adressen bekommen dieselbe Antwort wie bekannte (keine Kontenabfrage).

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/supabase/auth-redirect";
import { requestOrigin } from "@/lib/supabase/request-origin";

export type LoginState =
  | { status: "idle" }
  | { status: "invalid"; email: string }
  | { status: "rate_limited"; email: string }
  | { status: "failed"; email: string }
  | { status: "sent"; email: string };

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export async function requestMagicLink(
  _previous: LoginState,
  formData: FormData,
): Promise<LoginState> {
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const next = safeNextPath(String(formData.get("next") ?? ""));

  if (!EMAIL_PATTERN.test(email)) {
    return { status: "invalid", email };
  }

  const supabase = createSupabaseServerClient();
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: `${requestOrigin()}/auth/callback?next=${encodeURIComponent(next)}`,
      shouldCreateUser: false,
    },
  });

  if (!error) {
    return { status: "sent", email };
  }
  if (error.status === 429 || error.code === "over_email_send_rate_limit") {
    return { status: "rate_limited", email };
  }
  // GoTrue lehnt unbekannte Adressen bei shouldCreateUser=false ab. Nach aussen
  // gleiche Antwort wie bei einer bekannten Adresse.
  if (error.code === "otp_disabled" || error.code === "signup_disabled") {
    return { status: "sent", email };
  }
  return { status: "failed", email };
}
