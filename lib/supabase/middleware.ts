// Team Performance OS — Session-Refresh und Routenschutz in der Middleware.
// getUser() prueft das Token beim Auth-Server (nicht nur getSession() aus dem Cookie).
// Ohne gueltigen User: Trainer-Routen leiten auf /login um (Login-UI folgt in AP-31).

import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { supabaseEnv } from "./env";

// Routen der Gruppe app/(trainer). Neue Trainer-Seiten hier eintragen.
export const TRAINER_ROUTES = ["/dashboard"] as const;

function isTrainerRoute(pathname: string): boolean {
  return TRAINER_ROUTES.some(
    (route) => pathname === route || pathname.startsWith(`${route}/`),
  );
}

export async function updateSession(request: NextRequest) {
  const { url, anonKey } = supabaseEnv();
  let response = NextResponse.next({ request });

  const supabase = createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) =>
          request.cookies.set(name, value),
        );
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        );
        Object.entries(headers ?? {}).forEach(([key, value]) =>
          response.headers.set(key, value),
        );
      },
    },
  });

  // Nichts zwischen createServerClient und getUser() einfuegen (Refresh-Reihenfolge).
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user && isTrainerRoute(request.nextUrl.pathname)) {
    const loginUrl = request.nextUrl.clone();
    loginUrl.pathname = "/login";
    loginUrl.search = "";
    loginUrl.searchParams.set("next", request.nextUrl.pathname);
    return NextResponse.redirect(loginUrl);
  }

  return response;
}
