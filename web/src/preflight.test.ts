import { describe, expect, it } from "vitest";
import { preflightGate } from "./exam";

describe("preflightGate", () => {
  it("ok 가 false 인데 실패 항목이 없으면 통과로 보지 않는다", () => {
    const odd = { ok: false, checks: [{ id: "engine" as const, ok: true, message: "엔진", help_url: "" }] };
    expect(preflightGate(odd, "exam").canStart).toBe(false);
    expect(preflightGate(odd, "exam").warnings.length).toBeGreaterThan(0);
    expect(preflightGate(odd, "practice").canStart).toBe(true);
  });
});
