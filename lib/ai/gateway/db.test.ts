// Team Performance OS — Tests der Datenbank-Kapselung des KI-Gateways
// (lib/ai/gateway/db.ts, AP-70a). Fixrunde Code-Review P1: readDoor() wirft
// bei einem nicht gelisteten Namen (verifiziert), war aber bei AP-69 nie
// aufgerufen (dataDoors: []) und deshalb ungetestet. Mockt die Registry
// (lib/ai/gateway/purposes.ts) mit einer Test-Spec, die EINE dataDoor traegt,
// damit auch der Erfolgsfall (a) getestet werden kann.

import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

vi.mock("./purposes", () => ({
  GATEWAY_FINISH_DOOR: "rpc_finish_model_call",
  purposeSpec: () => ({
    openDoor: "rpc_test_open",
    dataDoors: ["irgendeine_tuer"],
    writeDoors: [],
    provider: "jev",
  }),
}));

import { gatewayDb } from "./db";

describe("gatewayDb.readDoor", () => {
  it("(a) ein erlaubter Name (in dataDoors der Zweck-Spec) wird durchgelassen", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { ok: true }, error: null });
    const db = gatewayDb("ap69_squad_check", { rpc } as unknown as Parameters<typeof gatewayDb>[1]);

    const result = await db.readDoor("irgendeine_tuer", { p_foo: "bar" });

    expect(result).toEqual({ data: { ok: true }, error: null });
    expect(rpc).toHaveBeenCalledWith("irgendeine_tuer", { p_foo: "bar" });
  });

  it("(b) ein NICHT gelisteter Name wirft, ohne die Datenbank zu erreichen", async () => {
    const rpc = vi.fn();
    const db = gatewayDb("ap69_squad_check", { rpc } as unknown as Parameters<typeof gatewayDb>[1]);

    await expect(db.readDoor("nicht_erlaubte_tuer", {})).rejects.toThrow(
      /"nicht_erlaubte_tuer" ist keine dataDoor/,
    );
    expect(rpc).not.toHaveBeenCalled();
  });
});

describe("gatewayDb.finish", () => {
  it("ruft immer die gemeinsame Abschluss-Tuer mit den p_-Feldern auf", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { call_id: 1 }, error: null });
    const db = gatewayDb("ap69_squad_check", { rpc } as unknown as Parameters<typeof gatewayDb>[1]);

    await db.finish({ callId: 1, resultClass: "ok", latencyMs: 12, finishToken: "tok" });

    expect(rpc).toHaveBeenCalledWith("rpc_finish_model_call", {
      p_call_id: 1,
      p_result_class: "ok",
      p_latency_ms: 12,
      p_finish_token: "tok",
    });
  });
});
