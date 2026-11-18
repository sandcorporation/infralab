// target: web/src/spec/spec_exam_invites.test.ts
// AC: #70: 응시 링크 주소는 <오리진>/exam/<토큰> 이다(웹)
// AC: #70: 응시 링크 발급(201) — 화면이 쓰는 API 클라이언트가 회차의 exam-invites 경로로 POST 한다
//
// 담당자 화면이 쓰는 함수(web/src/api.ts)를 본다: 복사 버튼이 클립보드에 넣는 응시 링크 주소와, 발급 버튼이 부르는
// 요청의 경로·메서드·본문. 화면 자체(복사 버튼, 회수된 상태 표시)는 티켓의 「손 확인」이다.
import { afterEach, describe, expect, it, vi } from "vitest";
import { examInviteUrl, instructor } from "../api";
import type { ExamInvite } from "../api";

afterEach(() => vi.unstubAllGlobals());

describe("응시 링크", () => {
  it("응시 링크는 <오리진>/exam/<토큰> 이다", () => {
    vi.stubGlobal("location", { origin: "https://infralab.test" });
    expect(examInviteUrl("tok123")).toBe("https://infralab.test/exam/tok123");
  });

  it("발급은 회차의 exam-invites 경로로 이름표를 실어 POST 한다", async () => {
    const issued: ExamInvite = {
      id: 7,
      label: "지원자 A",
      token: "tok123",
      status: "invited",
      created_at: "2026-11-18T09:00:00Z",
      started_at: null,
      finished_at: null,
    };
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(issued), { status: 201 }));
    vi.stubGlobal("fetch", fetchMock);

    const out = await instructor.createExamInvite(3, "지원자 A");

    expect(out).toEqual(issued);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/api/instructor/cohorts/3/exam-invites");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ label: "지원자 A" });
  });
});
