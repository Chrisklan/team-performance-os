"use server";

// Team Performance OS — eigenes Passwort festlegen oder aendern (Server Action).
// Laeuft mit dem JWT der angemeldeten Person. Setzt zusaetzlich den Merker
// password_set in user_metadata, damit nach dem naechsten Anmeldelink kein Angebot mehr kommt.

import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/supabase/auth-redirect";
import { passwordProblem, PASSWORD_SET_FLAG, type PasswordProblem } from "@/lib/supabase/password";
import { appRoleFromClaims, homePathForRole } from "@/lib/medical/role";

export type SetPasswordState =
  | { status: "idle" }
  | { status: PasswordProblem }
  | { status: "same_password" }
  | { status: "weak" }
  | { status: "unauthenticated" }
  | { status: "rate_limited" }
  | { status: "failed" };

export async function setOwnPassword(
  _previous: SetPasswordState,
  formData: FormData,
): Promise<SetPasswordState> {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm") ?? "");
  const rawNext = String(formData.get("next") ?? "");

  const problem = passwordProblem(password, confirm);
  if (problem) return { status: problem };

  const supabase = createSupabaseServerClient();
  const { error } = await supabase.auth.updateUser({
    password,
    data: { [PASSWORD_SET_FLAG]: true },
  });

  if (error) {
    if (error.code === "same_password") return { status: "same_password" };
    if (error.code === "weak_password") return { status: "weak" };
    if (error.status === 401 || error.code === "session_not_found" || error.code === "no_authorization") {
      return { status: "unauthenticated" };
    }
    if (error.status === 429) return { status: "rate_limited" };
    return { status: "failed" };
  }

  if (rawNext) redirect(safeNextPath(rawNext));
  const { data } = await supabase.auth.getClaims();
  redirect(homePathForRole(appRoleFromClaims(data?.claims)));
}
