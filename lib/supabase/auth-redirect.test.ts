import { describe, expect, it } from "vitest";
import { safeNextPath } from "./auth-redirect";

describe("safeNextPath", () => {
  it("lässt interne Pfade durch", () => {
    expect(safeNextPath("/dashboard")).toBe("/dashboard");
    expect(safeNextPath("/dashboard/spieler?x=1")).toBe("/dashboard/spieler?x=1");
  });
  it("fällt bei fehlendem Wert auf /dashboard", () => {
    expect(safeNextPath(null)).toBe("/dashboard");
    expect(safeNextPath("")).toBe("/dashboard");
  });
  it.each(["//evil.com", "https://evil.com", "/\\evil.com", "evil.com", "javascript:alert(1)"])(
    "verwirft %s (Open Redirect)",
    (raw) => {
      expect(safeNextPath(raw)).toBe("/dashboard");
    },
  );
  it("verhindert Schleifen in die Auth-Routen", () => {
    expect(safeNextPath("/login")).toBe("/dashboard");
    expect(safeNextPath("/auth/callback?code=1")).toBe("/dashboard");
  });
});
