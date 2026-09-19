// Team Performance OS — Abmelden. Nur POST (Formular), damit ein Link oder ein
// Bild-Tag niemanden abmelden kann. 303 sorgt dafuer, dass der Browser /login per GET holt.

import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function POST(request: NextRequest) {
  const supabase = createSupabaseServerClient();
  await supabase.auth.signOut();
  const loginUrl = new URL("/login", request.nextUrl.origin);
  loginUrl.searchParams.set("notice", "signedout");
  return NextResponse.redirect(loginUrl, { status: 303 });
}
