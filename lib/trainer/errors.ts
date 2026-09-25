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
  | "NOT_FOUND"
  | "NETWORK"
  | "MODULE_DISABLED"
  | "RPC_FAILED";

type RpcErrorLike = { code?: string | null; message?: string | null };

// Ordnet einen PostgREST-Fehler einem Zustand zu. Reine Funktion, damit sie testbar ist.
//  * status 0 (Fetch gescheitert)      -> NETWORK
//  * 42501 (FORBIDDEN, permission)     -> FORBIDDEN
//  * PGRST301 / PGRST303 (JWT ungueltig, abgelaufen) -> UNAUTHENTICATED
//  * P0002 oder HTTP 404 (nicht gefunden)  -> NOT_FOUND. Seit Punkt 64 antworten die
//    Tueren darauf mit 404 statt 500; die Oberflaeche zeigt "gibt es nicht" statt
//    "Server kaputt".
//  * 55000 (MODULE_DISABLED, LoadDeviation) -> MODULE_DISABLED. Keine Rechtefrage
//    (Modul-LoadDeviation.md Abschnitt 7), sondern eine Produktentscheidung des
//    Arztes -- kein Fehlerzustand, sondern ein ruhiger Hinweis.
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
  if (error.code === "P0002" || status === 404) {
    return new KaderAccessError("Nicht gefunden.", "NOT_FOUND", error.code || "404");
  }
  if (error.code === "55000") {
    return new KaderAccessError("Modul nicht freigeschaltet.", "MODULE_DISABLED", "55000");
  }
  return new KaderAccessError(
    `Kader konnte nicht geladen werden (${error.code || "unbekannt"}).`,
    "RPC_FAILED",
    error.code || undefined,
  );
}
