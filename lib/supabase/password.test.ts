import { describe, expect, it } from "vitest";
import { hasOwnPassword, passwordProblem, PASSWORD_MIN_LENGTH } from "./password";

describe("passwordProblem", () => {
  it("lässt ein ausreichend langes, bestätigtes Passwort durch", () => {
    expect(passwordProblem("zehnzeichen", "zehnzeichen")).toBeNull();
  });
  it("meldet zu kurz vor allem anderen", () => {
    const short = "a".repeat(PASSWORD_MIN_LENGTH - 1);
    expect(passwordProblem(short, "anders")).toBe("too_short");
  });
  it("zählt Bytes, nicht Zeichen, für die bcrypt-Grenze", () => {
    expect(passwordProblem("a".repeat(72), "a".repeat(72))).toBeNull();
    expect(passwordProblem("a".repeat(73), "a".repeat(73))).toBe("too_long");
    // 37 Umlaute sind 37 Zeichen, aber 74 Bytes
    expect(passwordProblem("ä".repeat(37), "ä".repeat(37))).toBe("too_long");
  });
  it("meldet abweichende Bestätigung", () => {
    expect(passwordProblem("zehnzeichen", "zehnzeichem")).toBe("mismatch");
  });
});

describe("hasOwnPassword", () => {
  it("ist nur bei ausdrücklichem true gesetzt", () => {
    expect(hasOwnPassword({ password_set: true })).toBe(true);
    expect(hasOwnPassword({ password_set: "true" })).toBe(false);
    expect(hasOwnPassword({})).toBe(false);
    expect(hasOwnPassword(null)).toBe(false);
    expect(hasOwnPassword(undefined)).toBe(false);
  });
});
