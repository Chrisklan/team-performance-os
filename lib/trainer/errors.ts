// Team Performance OS — Fehlermodell des Kader-Abrufs (rein, ohne Next/Supabase-Importe,
// damit es ohne Server-Kontext testbar ist).

export class KaderAccessError extends Error {
  constructor(
    message: string,
    readonly code: KaderErrorCode,
    readonly detail?: string,
  ) {
    super(message);
    this.name = "KaderAccessError";
  }
}

export type KaderErrorCode =
  | "UNAUTHENTICATED"
  | "FORBIDDEN"
  | "NETWORK"
  | "RPC_FAILED";

type RpcErrorLike = { code?: string | null; message?: string | null };

// Ordnet einen PostgREST-Fehler einem Zustand zu. Reine Funktion, damit sie testbar ist.
//  * status 0 (Fetch gescheitert)      -> NETWORK
//  * 42501 (FORBIDDEN, permission)     -> FORBIDDEN
//  * PGRST301 / PGRST303 (JWT ungueltig, abgelaufen) -> UNAUTHENTICATED
//  * alles andere                       -> RPC_FAILED mit Code als Detail
export function classifyRpcError(
  error: RpcErrorLike,
  status: number,
): KaderAccessError {
  if (status === 0) {
    return new KaderAccessError("Server nicht erreichbar.", "NETWORK");
  }
  if (error.code === "42501") {
    return new KaderAccessError("Kein Zugriff auf den Kader.", "FORBIDDEN", "42501");
  }
  if (error.code === "PGRST301" || error.code === "PGRST303") {
    return new KaderAccessError("Sitzung ungültig.", "UNAUTHENTICATED", error.code);
  }
  return new KaderAccessError(
    `Kader konnte nicht geladen werden (${error.code || "unbekannt"}).`,
    "RPC_FAILED",
    error.code || undefined,
  );
}
