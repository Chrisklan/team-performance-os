// Team Performance OS — Aufruf von TypeSafe JEV ueber OpenRouter (AP-69).
// NUR serverseitig. Wird ausschliesslich aus Server Actions ("use server")
// importiert, nie aus einer Client-Komponente (lib/ai/guardrails.test.ts prueft
// das per Grep). Kein NEXT_PUBLIC_, kein Service Role Key (ADR-019 §3.3): der
// Datenbankzugriff laeuft vorher ueber die rollengepruefte Tuer mit dem JWT der
// anfragenden Person, dieses Modul kennt keine Datenbank.
//
// Bewusste Ausnahme von ADR-019 §3.6 (Router ohne AVV), von Chris am 2026-09-27
// bestaetigt, siehe backend/41_jev_switch_model_call_log.sql Kopfkommentar.
//
// Regeln (ADR-019 §3.7): Request- und Response-Bodies werden NIE geloggt, auch
// nicht bei Fehlern. Bei Fehlern wird hoechstens der HTTP-Statuscode
// weitergegeben. Keine Wiederholung: ein Fehler faellt auf die Regel v1 zurueck.

// "server-only" bricht den Build hart ab, falls die Datei je in einen
// Client-Pfad gelangt (Code-Review 2026-09-27). Der Grep-Test in
// lib/ai/guardrails.test.ts bleibt als zweite Ebene.
import "server-only";
import type { JevRequest } from "@/lib/ai/jevTypes";
// AP-70b Konsolidierung: enabled/apiKey kamen bisher redundant sowohl hier ALS
// AUCH in lib/ai/gateway/config.ts::readGatewaySwitchConfig aus derselben
// Umgebungsvariablen-Logik (JEV_ENABLED/OPENROUTER_API_KEY) -- eine Aenderung
// an einer Stelle wirkte nicht zuverlaessig auf die andere. readGatewaySwitchConfig
// ist jetzt die EINZIGE Quelle fuer das Betreiber-Notaus (enabled) und den API-Key,
// readJevConfig ruft sie auf und ergaenzt nur noch die AP-69-spezifischen Felder
// (provider/model/timeoutMs/minConfidence).
import { readGatewaySwitchConfig } from "@/lib/ai/gateway/config";

export const OPENROUTER_DECISIONS_ENDPOINT = "https://openrouter.ai/api/alpha/decisions";

export type JevCallOutcome =
  | { kind: "ok"; body: unknown; latencyMs: number }
  | { kind: "timeout"; latencyMs: number }
  | { kind: "rate_limited"; status: number; latencyMs: number }
  | { kind: "http_error"; status: number; latencyMs: number }
  | { kind: "invalid"; latencyMs: number };

export type JevConfig = {
  enabled: boolean;
  provider: string;
  model: string | null;
  apiKey: string | null;
  timeoutMs: number;
  minConfidence: number;
};

function numberFromEnv(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

// Betreiber-Notaus: JEV laeuft nur, wenn JEV_ENABLED exakt "true" ist UND ein
// Key vorhanden ist. Unabhaengig vom Team-Schalter in app.module_flags.
// enabled/apiKey kommen aus readGatewaySwitchConfig (einzige Quelle, siehe
// Kopfkommentar) -- unveraendertes Verhalten (dieselbe JEV_ENABLED/
// OPENROUTER_API_KEY-Logik wie zuvor hier direkt).
export function readJevConfig(env: NodeJS.ProcessEnv = process.env): JevConfig {
  const { enabled, apiKey } = readGatewaySwitchConfig(env);
  const timeoutMs = numberFromEnv(env.JEV_TIMEOUT_MS, 3000);
  const minConfidence = numberFromEnv(env.JEV_MIN_CONFIDENCE, 0.7);
  return {
    enabled,
    provider: env.JEV_PROVIDER?.trim() || "openrouter",
    model: env.JEV_MODEL?.trim() || null,
    apiKey,
    timeoutMs: timeoutMs > 0 ? timeoutMs : 3000,
    minConfidence: minConfidence >= 0 && minConfidence <= 1 ? minConfidence : 0.7,
  };
}

export async function askJev(
  request: JevRequest,
  options: { model: string; apiKey: string; timeoutMs: number },
): Promise<JevCallOutcome> {
  const started = Date.now();
  const elapsed = () => Date.now() - started;
  let response: Response;
  try {
    response = await fetch(OPENROUTER_DECISIONS_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${options.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ model: options.model, state: request.state, questions: request.questions }),
      signal: AbortSignal.timeout(options.timeoutMs),
      cache: "no-store",
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    if (name === "TimeoutError" || name === "AbortError") return { kind: "timeout", latencyMs: elapsed() };
    return { kind: "http_error", status: 0, latencyMs: elapsed() };
  }

  if (response.status === 429) {
    return { kind: "rate_limited", status: 429, latencyMs: elapsed() };
  }
  if (!response.ok) {
    return { kind: "http_error", status: response.status, latencyMs: elapsed() };
  }

  try {
    const body: unknown = await response.json();
    return { kind: "ok", body, latencyMs: elapsed() };
  } catch (error) {
    // Der Timeout gilt auch fuer das Lesen des Bodys.
    const name = error instanceof Error ? error.name : "";
    if (name === "TimeoutError" || name === "AbortError") return { kind: "timeout", latencyMs: elapsed() };
    return { kind: "invalid", latencyMs: elapsed() };
  }
}
