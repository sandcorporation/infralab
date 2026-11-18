// 응시 링크 enter 가 세션을 바꾸는 동안 me·내 기수 요청을 내보내지 않는다(#122). 다른 사용자로 로그인된 브라우저에서
// 옛 쿠키로 나간 요청은 401 을 받고, 그 응답이 enter 의 새 세션 쿠키를 지운다.
import { afterEach, describe, expect, it, vi } from "vitest";
import { getMe, getMyCohort } from "./api";
import { enterExam, examComposeUrl } from "./exam";

afterEach(() => vi.unstubAllGlobals());

const STATUS = { cohort_id: 3, cohort_name: "채용", status: "invited", replaced_login: true };

function stubFetch() {
  const calls: string[] = [];
  let finishEnter: (res: Response) => void = () => {};
  const fetchMock = vi.fn((path: string) => {
    calls.push(path);
    if (path.endsWith("/enter")) return new Promise<Response>((resolve) => (finishEnter = resolve));
    return Promise.resolve(new Response(JSON.stringify({ id: 1 }), { status: 200 }));
  });
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("window", { dispatchEvent: () => true });
  return { calls, finishEnter: (res: Response) => finishEnter(res) };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("응시 링크 enter 와 인증 요청의 순서", () => {
  it("enter 가 끝나기 전에는 me·내 기수 요청이 나가지 않고, 끝나면 나간다", async () => {
    const { calls, finishEnter } = stubFetch();

    const entered = enterExam("tok");
    const me = getMe();
    const cohort = getMyCohort(3);
    await flush();
    expect(calls).toEqual(["/api/exam/tok/enter"]);

    finishEnter(new Response(JSON.stringify(STATUS), { status: 200 }));
    expect((await entered).replaced_login).toBe(true);
    await Promise.all([me, cohort]);
    expect(calls.slice(1).sort()).toEqual(["/api/accounts/me", "/api/cohorts/3"]);
  });

  it("enter 가 실패해도 붙잡아 둔 요청은 나간다", async () => {
    const { calls, finishEnter } = stubFetch();

    const entered = enterExam("tok");
    const me = getMe();
    await flush();
    expect(calls).toEqual(["/api/exam/tok/enter"]);

    finishEnter(new Response(JSON.stringify({ detail: "없음" }), { status: 404 }));
    await expect(entered).rejects.toThrow("없음");
    await me;
    expect(calls).toEqual(["/api/exam/tok/enter", "/api/accounts/me"]);
  });
});

describe("설치 프로그램 compose 주소", () => {
  it("응시 토큰으로 받는 주소", () => {
    expect(examComposeUrl("https://infralab.sandcorp.co.kr", "a/b")).toBe(
      "https://infralab.sandcorp.co.kr/api/exam/a%2Fb/compose.yml",
    );
  });
});
