// Team Performance OS — gemeinsamer Ablauf eines Modellaufrufs (AP-70a).
// NUR serverseitig. Jeder Zweck (AP-69 heute, AP-70b spaeter) baut eine
// ModelCallSpec und ruft runModelCall auf -- der Ablauf selbst (Notaus,
// Tuer oeffnen, Modell-Pin pruefen, Anfrage bauen, Provider rufen, parsen,
// Ausgangswaechter, abschliessen, Fallback bei jeder Ausnahme) steht hier
// EINMAL, nicht mehr je Zweck dupliziert.
//
// Niemals call_id, finish_token oder eine Konfidenz nach aussen (Rueckgabe
// traegt nur status/output) -- Aufrufer bekommen ausschliesslich, was der
// jeweilige guard() ausdruecklich in output legt.

import "server-only";
import { gatewayDb } from "./db";
import { readGatewaySwitchConfig } from "./config";
import { forbiddenKeyHits, g01ViolationsInStringValues } from "./guard";
import type { PurposeKey, PurposeTypeMap } from "./purposes";

export type GatewayRunStatus = "off" | "fallback" | "empty" | "rejected" | "ok" | "partial";

export type GatewayRunResult<Out> = { status: GatewayRunStatus; output: Out };

export type ProviderOutcome =
  | { kind: "ok"; body: unknown; latencyMs: number }
  | { kind: "timeout"; latencyMs: number }
  | { kind: "invalid"; latencyMs: number }
  | { kind: "rate_limited"; status: number; latencyMs: number }
  | { kind: "http_error"; status: number; latencyMs: number };

export type ParseOutcome<Parsed> = {
  resultClass: "ok" | "partial" | "invalid";
  parsed: Parsed;
};

export type GuardOutcome<Out> = { ok: true; output: Out } | { ok: false };

// Rohe Antwort der Tueroeffner-Tuer (app._mg_open dahinter): call_id/
// finish_token/model stehen bei jedem Zweck an derselben Stelle, der Rest ist
// zweckspezifisch (z.B. candidates/refs/session bei AP-69).
export type GatewayOpenPayload = {
  call_id: number | null;
  finish_token?: string;
  model?: string;
  [key: string]: unknown;
};

// Code-Review P1 (Fixrunde): ModelCallSpec ist jetzt an PurposeTypeMap[P]
// gebunden statt vier freie Generics zu haben -- ein falsch verdrahteter
// Zweck (z.B. AP-70b-Typen unter purpose: 'ap69_squad_check') wird ein
// Typfehler, nicht mehr klaglos akzeptiert.
export type ModelCallSpec<P extends PurposeKey> = {
  purpose: P;
  // Erwartetes, gepinntes Modell -- wird gegen die Rueckgabe der Tuer
  // geprueft (ADR-019 §3.2: nie ein abweichend konfiguriertes Modell still
  // benutzen).
  model: string;
  emptyOutput: PurposeTypeMap[P]["Out"];
  fallbackOutput: PurposeTypeMap[P]["Out"];
  apiKey: string | null;
  timeoutMs: number;
  openArgs: Record<string, unknown>;
  toCtx: (openPayload: GatewayOpenPayload) => PurposeTypeMap[P]["Ctx"];
  buildRequest: (ctx: PurposeTypeMap[P]["Ctx"]) => PurposeTypeMap[P]["Req"] | null;
  callProvider: (
    request: PurposeTypeMap[P]["Req"],
    opts: { model: string; apiKey: string; timeoutMs: number },
  ) => Promise<ProviderOutcome>;
  parse: (body: unknown, ctx: PurposeTypeMap[P]["Ctx"]) => ParseOutcome<PurposeTypeMap[P]["Parsed"]>;
  // PFLICHT-Ausgangswaechter. ok:false -> Ergebnisklasse 'rejected', der
  // Aufrufer bekommt fallbackOutput. Laeuft NACH dem gemeinsamen, nicht
  // uebersteuerbaren Roh-Antwort-Check unten (forbiddenKeyHits/g01Violations).
  guard: (
    parsed: PurposeTypeMap[P]["Parsed"],
    ctx: PurposeTypeMap[P]["Ctx"],
  ) => GuardOutcome<PurposeTypeMap[P]["Out"]>;
  // Nur fuer HTTP-Fehler/Drosselung -- niemals Body/Request/Response loggen
  // (ADR-019 §3.7). Optional, Standard: kein Log.
  onProviderError?: (outcome: Exclude<ProviderOutcome, { kind: "ok" }>) => void;
};

function isDenial(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as Record<string, unknown>).code === "42501"
  );
}

async function finishQuiet(
  db: ReturnType<typeof gatewayDb>,
  callId: number,
  resultClass: string,
  latencyMs: number | null,
  finishToken: string,
): Promise<void> {
  try {
    await db.finish({
      callId,
      resultClass,
      latencyMs: latencyMs === null ? null : Math.max(0, Math.round(latencyMs)),
      finishToken,
    });
  } catch {
    // Bewusst ignoriert (wie bisher, AP-69): die Protokollzeile bleibt
    // sichtbar in ihrem letzten Zustand stehen.
  }
}

export async function runModelCall<P extends PurposeKey>(
  spec: ModelCallSpec<P>,
): Promise<GatewayRunResult<PurposeTypeMap[P]["Out"]>> {
  const gwSwitch = readGatewaySwitchConfig();
  if (!gwSwitch.enabled || spec.apiKey === null) {
    return { status: "off", output: spec.fallbackOutput };
  }

  const apiKey = spec.apiKey;

  try {
    const db = gatewayDb(spec.purpose);
    const { data, error } = await db.open(spec.openArgs);
    if (error || !data || isDenial(data)) {
      return { status: "fallback", output: spec.fallbackOutput };
    }

    const openPayload = data as GatewayOpenPayload;
    const callId = typeof openPayload.call_id === "number" ? openPayload.call_id : null;

    if (callId === null) {
      return { status: "empty", output: spec.emptyOutput };
    }

    const finishToken = typeof openPayload.finish_token === "string" ? openPayload.finish_token : null;
    if (!finishToken) {
      // Ohne Token kann kein Abschluss verifiziert werden -- die Zeile bleibt
      // bewusst pending statt einen Abschluss ohne Nachweis zu riskieren.
      return { status: "fallback", output: spec.fallbackOutput };
    }

    const openModel = typeof openPayload.model === "string" ? openPayload.model : null;
    if (!openModel || openModel !== spec.model) {
      await finishQuiet(db, callId, "invalid", null, finishToken);
      return { status: "fallback", output: spec.fallbackOutput };
    }

    const ctx = spec.toCtx(openPayload);
    const request = spec.buildRequest(ctx);
    if (!request) {
      await finishQuiet(db, callId, "invalid", null, finishToken);
      return { status: "fallback", output: spec.fallbackOutput };
    }

    const outcome = await spec.callProvider(request, { model: openModel, apiKey, timeoutMs: spec.timeoutMs });
    if (outcome.kind !== "ok") {
      spec.onProviderError?.(outcome);
      await finishQuiet(db, callId, outcome.kind, outcome.latencyMs, finishToken);
      return { status: "fallback", output: spec.fallbackOutput };
    }

    // F2 (Security-Review, Fixrunde) + N1 (zweite Fixrunde): forbiddenKeyHits/
    // g01ViolationsInStringValues laufen PFLICHT auf dem ROHEN Modell-Response-
    // Body, als fester Teil des Ablaufs -- NICHT dem einzelnen guard() der Spec
    // ueberlassen, das den Body bereits zweckspezifisch umgeformt (parsed)
    // sieht. Ein Modell, das einen verbotenen Schluessel oder einen G-01-Begriff
    // einschmuggelt, wird hier abgelehnt, bevor irgendein parse()/guard() ihn
    // ueberhaupt erreicht.
    //
    // N1: forbiddenKeyHits prueft SCHLUESSELNAMEN (das ist gewollt, Sperrliste
    // ist auf Schluessel gemuenzt). g01ViolationsInStringValues dagegen prueft
    // NUR String-BLATTWERTE, nicht den gesamten serialisierten JSON-Text und
    // nicht Schluesselnamen -- ein urspruenglicher JSON.stringify(outcome.body)
    // haette jeden Schluesselnamen mitgeprueft, und eine echte JEV-Choice-
    // Antwort (Form { choice, probabilities: {...}, confidence }) triggerte
    // damit IMMER faelschlich, weil "probabilities" den G-01-Begriff "probab"
    // als Teilstring enthaelt -- jede echte Antwort waere in Produktion
    // verworfen worden.
    const rawForbiddenHits = forbiddenKeyHits(outcome.body);
    const rawG01Hits = g01ViolationsInStringValues(outcome.body);
    if (rawForbiddenHits.length > 0 || rawG01Hits.length > 0) {
      await finishQuiet(db, callId, "rejected", outcome.latencyMs, finishToken);
      return { status: "rejected", output: spec.fallbackOutput };
    }

    const parsed = spec.parse(outcome.body, ctx);
    if (parsed.resultClass === "invalid") {
      await finishQuiet(db, callId, "invalid", outcome.latencyMs, finishToken);
      return { status: "fallback", output: spec.fallbackOutput };
    }

    const guarded = spec.guard(parsed.parsed, ctx);
    if (!guarded.ok) {
      await finishQuiet(db, callId, "rejected", outcome.latencyMs, finishToken);
      return { status: "rejected", output: spec.fallbackOutput };
    }

    await finishQuiet(db, callId, parsed.resultClass, outcome.latencyMs, finishToken);
    return { status: parsed.resultClass === "ok" ? "ok" : "partial", output: guarded.output };
  } catch {
    return { status: "fallback", output: spec.fallbackOutput };
  }
}
