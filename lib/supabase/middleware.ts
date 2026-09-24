// Team Performance OS — Session-Refresh und Routenschutz in der Middleware.
// getUser() prueft das Token beim Auth-Server (nicht nur getSession() aus dem Cookie).
// Ohne gueltigen User: Trainer-Routen leiten auf /login um. Mit gueltigem User geht
// /login direkt weiter aufs Dashboard.
// Ist der Auth-Server nicht erreichbar, wird nicht auf /login umgeleitet: das waere
// ein falscher Befund ("nicht angemeldet"). Die Seite meldet dann selbst NETWORK.

import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { supabaseEnv } from "./env";
import { appRoleFromClaims, homePathForRole } from "@/lib/medical/role";

// Routen, die eine Anmeldung brauchen: app/(trainer), app/(medizin) und app/konto.
// Neue geschuetzte Seiten hier eintragen. Die Rolle prueft die Seite selbst.
export const TRAINER_ROUTES = ["/dashboard"] as const;
export const MEDICAL_ROUTES = ["/medizin"] as const;
// Eigenes Konto (Passwort festlegen), fuer jede Rolle.
export const ACCOUNT_ROUTES = ["/konto"] as const;
const PROTECTED_ROUTES = [...TRAINER_ROUTES, ...MEDICAL_ROUTES, ...ACCOUNT_ROUTES];

function isProtectedRoute(pathname: string): boolean {
  return PROTECTED_ROUTES.some(
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
    error: userError,
  } = await supabase.auth.getUser();

  const authServerUnreachable = userError?.name === "AuthRetryableFetchError";

  if (user && request.nextUrl.pathname === "/login") {
    // Startseite je Rolle: Physio und Arzt in die Medizinsicht. Die Rolle hier
    // entscheidet nur die Weiterleitung, jede Seite prueft sie selbst noch einmal.
    const { data } = await supabase.auth.getClaims();
    const dashboardUrl = request.nextUrl.clone();
    dashboardUrl.pathname = homePathForRole(appRoleFromClaims(data?.claims));
    dashboardUrl.search = "";
    return NextResponse.redirect(dashboardUrl);
  }

  if (!user && !authServerUnreachable && isProtectedRoute(request.nextUrl.pathname)) {
    const loginUrl = request.nextUrl.clone();
    loginUrl.pathname = "/login";
    loginUrl.search = "";
    loginUrl.searchParams.set("next", request.nextUrl.pathname);
    return NextResponse.redirect(loginUrl);
  }

  return response;
}
