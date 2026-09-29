// AP-70a Schritt 0 — Charakterisierungstests fuer runJevSquadCheck, VOR jeder
// Aenderung an der Produktionslogik. Muessen auf dem heutigen, unveraenderten
// Code gruen laufen (Sicherheitsnetz fuer die Gateway-Umstellung, Schritt 2).
//
// Mockt den Supabase-Client (lib/supabase/server) und global fetch. Prueft die
// EXAKTEN Argumente, die der heutige Code an rpc_squad_check_jev_context und
// rpc_finish_model_call sendet, damit ein spaeterer Verhaltenswechsel (auch ein
// unbeabsichtigter) sichtbar wird.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const rpcMock = vi.fn();

vi.mock("@/lib/supabase/server", () => ({
  createSupabaseServerClient: () => ({ rpc: rpcMock }),
}));

// server-only wirft in jedem Modul, das es importiert, sobald es aus einem
// Client-Kontext geladen wird. Vitest laeuft ausserhalb von Next.js' RSC
// Boundary und zaehlt fuer das Paket immer als "Client" -> in Tests entschaerfen.
vi.mock("server-only", () => ({}));

import { runJevSquadCheck } from "./squadCheckActions";

const SESSION_ID = "11111111-1111-1111-1111-111111111111";
const DURATION = 60;
const INTENSITY = 5;

const BASE_ENV: Record<string, string> = {
  JEV_ENABLED: "true",
  OPENROUTER_API_KEY: "key-123",
  JEV_CONTEXT_SECRET: "server-secret-value-for-tests",
};

function setEnv(overrides: Record<string, string | undefined> = {}) {
  const merged = { ...BASE_ENV, ...overrides };
  for (const [key, value] of Object.entries(merged)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

function clearJevEnv() {
  for (const key of [
    "JEV_ENABLED",
    "OPENROUTER_API_KEY",
    "JEV_CONTEXT_SECRET",
    "JEV_MODEL",
    "JEV_TIMEOUT_MS",
    "JEV_MIN_CONFIDENCE",
    "JEV_PROVIDER",
  ]) {
    delete process.env[key];
  }
}

const CANDIDATE = {
  ref: "A01",
  band: "moderate",
  planned_load_vs_own_norm: "normal",
  released_deviations_7d: [],
};

function contextOk(overrides: Record<string, unknown> = {}) {
  return {
    call_id: 42,
    finish_token: "ffffffff-ffff-ffff-ffff-ffffffffffff",
    provider: "openrouter",
    model: "typesafe/jev-1.13",
    rule_version: "v1",
    session: { duration_min: DURATION, planned_intensity: INTENSITY, session_type: "field" },
    candidates: [CANDIDATE],
    refs: [{ ref: "A01", person_id: "22222222-2222-2222-2222-222222222222" }],
    ...overrides,
  };
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  clearJevEnv();
  setEnv();
  rpcMock.mockReset();
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  clearJevEnv();
});

const CONTEXT_ARGS = {
  p_session_id: SESSION_ID,
  p_duration_min: DURATION,
  p_planned_intensity: INTENSITY,
  p_context_secret: "server-secret-value-for-tests",
};

// N1 (zweite Fixrunde): eine REALISTISCHE JEV-Choice-Antwort, wie sie das
// Modell tatsaechlich liefert (jev SKILL.md: choice/probabilities/confidence,
// plus usage auf oberster Ebene) -- nicht die verkuerzten { choice, confidence
// }-Mocks von vorher. "probabilities" enthaelt den G-01-Begriff "probab" als
// TEILSTRING seines SCHLUESSELNAMENS; das war genau der N1-Bug (run.ts pruefte
// vorher JSON.stringify(outcome.body) gegen G-01, also auch Schluesselnamen).
function jevChoiceAnswer(choice: string, confidence: number) {
  const probabilities =
    choice === "reduced"
      ? { full: 0.05, reduced: confidence, unclear: 1 - confidence - 0.05 }
      : { full: confidence, reduced: 0.05, unclear: 1 - confidence - 0.05 };
  return { choice, probabilities, confidence };
}

function jevResponseBody(answers: Record<string, unknown>, extra: Record<string, unknown> = {}) {
  return {
    answers,
    usage: { cost: 0.0000421, input_tokens: 612, output_tokens: 9 },
    ...extra,
  };
}

describe("runJevSquadCheck — Charakterisierung (heutiger Code, vor AP-70a)", () => {
  it("off: JEV_ENABLED nicht true -> off, keine RPCs, kein fetch", async () => {
    setEnv({ JEV_ENABLED: "false" });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "off", overlays: [] });
    expect(rpcMock).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("off: kein API-Key -> off", async () => {
    setEnv({ OPENROUTER_API_KEY: undefined });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "off", overlays: [] });
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("Tuer-Fehler: rpc_squad_check_jev_context liefert error -> fallback, kein finish-Aufruf", async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: { code: "XXOOO", message: "boom" } });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(rpcMock).toHaveBeenCalledTimes(1);
    expect(rpcMock).toHaveBeenNthCalledWith(1, "rpc_squad_check_jev_context", CONTEXT_ARGS);
  });

  it("deny (42501): rpc liefert Ablehnungsform -> fallback", async () => {
    rpcMock.mockResolvedValueOnce({ data: { code: "42501", message: "FORBIDDEN" }, error: null });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(rpcMock).toHaveBeenCalledTimes(1);
  });

  it("55000 (MODULE_DISABLED/RATE_LIMITED): rpc liefert error mit diesem Code -> fallback", async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: { code: "55000", message: "MODULE_DISABLED" } });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
  });

  it("keine Kandidaten: call_id null -> no_candidates, kein finish-Aufruf", async () => {
    rpcMock.mockResolvedValueOnce({
      data: { call_id: null, candidates: [], refs: [] },
      error: null,
    });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "no_candidates", overlays: [] });
    expect(rpcMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("fehlendes Token: call_id gesetzt, finish_token fehlt -> fallback, kein finish-Aufruf (kein Token zum Verifizieren)", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk({ finish_token: undefined }), error: null });
    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(rpcMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("abweichendes Modell: JEV_MODEL env weicht vom ctx.model ab -> finish 'invalid', fallback, kein fetch", async () => {
    setEnv({ JEV_MODEL: "some/other-model" });
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "invalid" }, error: null });

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(rpcMock).toHaveBeenCalledTimes(2);
    expect(rpcMock).toHaveBeenNthCalledWith(2, "rpc_finish_model_call", {
      p_call_id: 42,
      p_result_class: "invalid",
      p_latency_ms: null,
      p_finish_token: "ffffffff-ffff-ffff-ffff-ffffffffffff",
    });
  });

  it("Timeout: fetch wirft AbortError -> finish 'timeout' mit Latenz, fallback", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "timeout" }, error: null });
    fetchMock.mockImplementationOnce(() => {
      const err = new Error("aborted");
      err.name = "TimeoutError";
      return Promise.reject(err);
    });

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(rpcMock).toHaveBeenCalledTimes(2);
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_call_id).toBe(42);
    expect(finishArgs.p_result_class).toBe("timeout");
    expect(finishArgs.p_finish_token).toBe("ffffffff-ffff-ffff-ffff-ffffffffffff");
    expect(typeof finishArgs.p_latency_ms).toBe("number");
  });

  it("rate_limited: fetch antwortet 429 -> finish 'rate_limited', fallback, console.warn nur mit Statuscode", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "rate_limited" }, error: null });
    fetchMock.mockResolvedValueOnce(new Response(null, { status: 429 }));

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("rate_limited");
    expect(warnSpy).toHaveBeenCalledWith("JEV squad check: HTTP 429");
    warnSpy.mockRestore();
  });

  it("http_error: fetch antwortet 500 -> finish 'http_error', fallback", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "http_error" }, error: null });
    fetchMock.mockResolvedValueOnce(new Response(null, { status: 500 }));

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("http_error");
    expect(warnSpy).toHaveBeenCalledWith("JEV squad check: HTTP 500");
    warnSpy.mockRestore();
  });

  it("invalid: fetch antwortet 200 mit kaputtem JSON -> finish 'invalid', fallback", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "invalid" }, error: null });
    fetchMock.mockResolvedValueOnce(new Response("not-json", { status: 200 }));

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("invalid");
  });

  it("partial: eine gueltige Antwort fehlt -> status partial, finish 'partial', overlays leer wenn choice full", async () => {
    const ctx = contextOk({
      candidates: [CANDIDATE, { ...CANDIDATE, ref: "A02" }],
      refs: [
        { ref: "A01", person_id: "22222222-2222-2222-2222-222222222222" },
        { ref: "A02", person_id: "33333333-3333-3333-3333-333333333333" },
      ],
    });
    rpcMock.mockResolvedValueOnce({ data: ctx, error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "partial" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(jevResponseBody({ A01: jevChoiceAnswer("reduced", 0.9) })), { status: 200 }),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result.status).toBe("partial");
    expect(result.overlays).toEqual([
      { person_id: "22222222-2222-2222-2222-222222222222", suggestion: "reduced", hint_key: "j1", source: "jev" },
    ]);
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("partial");
  });

  it("ok: alle Antworten gueltig -> status ok, finish 'ok', overlays aus reduced-Antworten", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "ok" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(jevResponseBody({ A01: jevChoiceAnswer("reduced", 0.9) })), { status: 200 }),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({
      status: "ok",
      overlays: [
        { person_id: "22222222-2222-2222-2222-222222222222", suggestion: "reduced", hint_key: "j1", source: "jev" },
      ],
    });
    expect(rpcMock).toHaveBeenCalledTimes(2);
    expect(rpcMock).toHaveBeenNthCalledWith(1, "rpc_squad_check_jev_context", CONTEXT_ARGS);
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs).toEqual({
      p_call_id: 42,
      p_result_class: "ok",
      p_latency_ms: expect.any(Number),
      p_finish_token: "ffffffff-ffff-ffff-ffff-ffffffffffff",
    });
  });

  it("ok mit choice full: keine Overlays", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "ok" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(jevResponseBody({ A01: jevChoiceAnswer("full", 0.9) })), { status: 200 }),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "ok", overlays: [] });
  });

  // N1 (zweite Fixrunde, Pflicht-Test 1): der REGRESSIONSTEST fuer den Bug
  // selbst -- eine realistische JEV-Antwort mit "probabilities"-Schluessel
  // (enthaelt "probab" als Teilstring) MUSS zu 'ok' fuehren, nicht zu
  // 'rejected'. Vor dem N1-Fix (g01Violations auf JSON.stringify(outcome.body))
  // waere dieser Test rot gewesen: jede echte JEV-Antwort haette G-01
  // faelschlich ausgeloest, weil der Schluesselname selbst mitgeprueft wurde.
  it("N1: realistische JEV-Antwort mit probabilities-Feld fuehrt zu ok, NICHT zu rejected", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "ok" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(jevResponseBody({ A01: jevChoiceAnswer("reduced", 0.9) })), { status: 200 }),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result.status).toBe("ok");
    expect(result.overlays).toEqual([
      { person_id: "22222222-2222-2222-2222-222222222222", suggestion: "reduced", hint_key: "j1", source: "jev" },
    ]);
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("ok");
  });

  // N1 Pflicht-Test 2: ein verbotener SCHLUESSEL im rohen Response-Body (hier
  // "diagnosis", exakt aus FORBIDDEN_MODEL_RESPONSE_KEYS/FORBIDDEN_MEDICAL_KEYS)
  // muss weiterhin, unveraendert durch den N1-Fix, zu 'rejected' fuehren --
  // forbiddenKeyHits prueft Schluesselnamen und ist von der G-01-Aenderung
  // nicht betroffen.
  it("N1: verbotener Schluessel im rohen Response-Body -> finish rejected", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "rejected" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(
        JSON.stringify(jevResponseBody({ A01: jevChoiceAnswer("reduced", 0.9) }, { diagnosis: "unauffaellig" })),
        { status: 200 },
      ),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("rejected");
  });

  // N1 Pflicht-Test 3: ein G-01-Sperrbegriff in einem tatsaechlichen
  // STRING-WERT (nicht im Schluesselnamen) muss weiterhin zu 'rejected'
  // fuehren -- g01ViolationsInStringValues prueft String-Blattwerte, dieser
  // Fall darf durch den N1-Fix nicht verloren gehen.
  it("N1: G-01-Begriff in einem String-WERT (nicht Schluessel) -> finish rejected", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockResolvedValueOnce({ data: { call_id: 42, result_class: "rejected" }, error: null });
    fetchMock.mockResolvedValueOnce(
      new Response(
        JSON.stringify(
          jevResponseBody(
            { A01: jevChoiceAnswer("reduced", 0.9) },
            { explanation: "Erhoehtes Verletzungsrisiko erkannt" },
          ),
        ),
        { status: 200 },
      ),
    );

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);

    expect(result).toEqual({ status: "fallback", overlays: [] });
    const finishArgs = rpcMock.mock.calls[1][1] as Record<string, unknown>;
    expect(finishArgs.p_result_class).toBe("rejected");
  });

  it("finish-Fehler wird ignoriert: rpc_finish_model_call wirft -> trotzdem fallback statt Exception", async () => {
    rpcMock.mockResolvedValueOnce({ data: contextOk(), error: null });
    rpcMock.mockRejectedValueOnce(new Error("finish boom"));
    fetchMock.mockResolvedValueOnce(new Response(null, { status: 500 }));

    const result = await runJevSquadCheck(SESSION_ID, DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
  });

  it("ungueltige Eingaben (Session-ID keine UUID) -> fallback, keine RPCs", async () => {
    const result = await runJevSquadCheck("not-a-uuid", DURATION, INTENSITY);
    expect(result).toEqual({ status: "fallback", overlays: [] });
    expect(rpcMock).not.toHaveBeenCalled();
  });
});
