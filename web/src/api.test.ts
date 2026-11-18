import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, UNAUTHENTICATED_EVENT, getMe, loginUrl, logoutSession } from "./api";

afterEach(() => vi.unstubAllGlobals());

function stub(status: number, body: unknown = {}) {
  const fetchMock = vi.fn(async () => new Response(status === 204 ? null : JSON.stringify(body), { status }));
  const events: string[] = [];
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("window", { dispatchEvent: (e: Event) => events.push(e.type) });
  return { fetchMock, events };
}

describe("세션 쿠키 요청", () => {
  it("쿠키를 실어 보내고 Authorization 헤더는 붙이지 않는다", async () => {
    const { fetchMock } = stub(200, { id: 1 });
    await getMe();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/api/accounts/me");
    expect(init.credentials).toBe("same-origin");
    expect(new Headers(init.headers).has("Authorization")).toBe(false);
  });

  it("401 이면 로그아웃 상태를 알리고 ApiError 를 던진다", async () => {
    const { events } = stub(401, { detail: "Unauthorized" });
    await expect(getMe()).rejects.toBeInstanceOf(ApiError);
    expect(events).toEqual([UNAUTHENTICATED_EVENT]);
  });

  it("로그아웃은 /api/auth/logout 에 POST", async () => {
    const { fetchMock } = stub(204);
    await logoutSession();
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/api/auth/logout");
    expect(init.method).toBe("POST");
  });
});

describe("로그인 주소", () => {
  it("돌아올 경로를 next 로 싣는다", () => {
    expect(loginUrl("/instructor?x=1")).toBe("/api/auth/login?next=%2Finstructor%3Fx%3D1");
  });
});
