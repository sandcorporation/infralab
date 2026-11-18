import { afterEach, describe, expect, it, vi } from "vitest";
import { loadTokens, saveTokens } from "./api";

function memoryStorage(): Storage {
  const m = new Map<string, string>();
  return {
    get length() {
      return m.size;
    },
    clear: () => m.clear(),
    getItem: (k) => m.get(k) ?? null,
    key: (i) => [...m.keys()][i] ?? null,
    removeItem: (k) => void m.delete(k),
    setItem: (k, v) => void m.set(k, v),
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("토큰 저장", () => {
  it("저장한 토큰을 다시 읽고, null 을 저장하면 지운다", () => {
    vi.stubGlobal("localStorage", memoryStorage());
    saveTokens({ access: "a", refresh: "r" });
    expect(loadTokens()).toEqual({ access: "a", refresh: "r" });
    saveTokens(null);
    expect(loadTokens()).toBeNull();
  });

  it("저장소를 쓸 수 없으면 로그인하지 않은 것으로 본다", () => {
    vi.stubGlobal("localStorage", undefined);
    expect(loadTokens()).toBeNull();
    expect(() => saveTokens({ access: "a", refresh: "r" })).not.toThrow();
  });
});
