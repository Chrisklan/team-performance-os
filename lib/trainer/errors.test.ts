import { describe, expect, it } from "vitest";
import { classifyRpcError } from "./errors";

describe("classifyRpcError", () => {
  it("Fetch gescheitert (status 0) ist NETWORK", () => {
    expect(classifyRpcError({ code: "", message: "TypeError: fetch failed" }, 0).code).toBe("NETWORK");
  });
  it("42501 ist FORBIDDEN", () => {
    expect(classifyRpcError({ code: "42501" }, 403).code).toBe("FORBIDDEN");
  });
  it("PGRST301 und PGRST303 sind UNAUTHENTICATED", () => {
    expect(classifyRpcError({ code: "PGRST301" }, 401).code).toBe("UNAUTHENTICATED");
    expect(classifyRpcError({ code: "PGRST303" }, 401).code).toBe("UNAUTHENTICATED");
  });
  it("P0002 ist NOT_FOUND, nicht RPC_FAILED (Punkt 64)", () => {
    const e = classifyRpcError({ code: "P0002" }, 404);
    expect(e.code).toBe("NOT_FOUND");
    expect(e.detail).toBe("P0002");
  });
  it("HTTP 404 ohne Code ist NOT_FOUND", () => {
    expect(classifyRpcError({ code: null }, 404).code).toBe("NOT_FOUND");
  });
  it("P0002 ueber den alten Weg (HTTP 500) ist trotzdem NOT_FOUND", () => {
    expect(classifyRpcError({ code: "P0002" }, 500).code).toBe("NOT_FOUND");
  });
  it("alles andere ist RPC_FAILED mit Code als Detail", () => {
    const e = classifyRpcError({ code: "XX000" }, 500);
    expect(e.code).toBe("RPC_FAILED");
    expect(e.detail).toBe("XX000");
  });
  it("ohne Code bleibt RPC_FAILED, kein NETWORK", () => {
    expect(classifyRpcError({ code: null }, 500).code).toBe("RPC_FAILED");
  });
});
