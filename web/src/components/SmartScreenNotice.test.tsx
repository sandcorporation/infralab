import { renderToString } from "react-dom/server";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

vi.mock("../auth", () => ({ useAuth: () => ({ me: null, refreshMe: vi.fn() }) }));
vi.mock("../hooks", () => ({
  useMyCohort: () => ({
    cohort: { id: 1, name: "1기", agent_url: undefined, agent_token: undefined },
    error: null,
    setCohort: vi.fn(),
  }),
}));
vi.mock("../examAttempt", () => ({
  useExamClock: () => ({
    token: "t",
    status: {
      cohort_id: 1,
      cohort_name: "채용 시험",
      status: "invited",
      time_limit_minutes: 90,
      tools: [],
      proctoring: false,
      started_at: null,
      deadline: null,
      remaining_seconds: null,
      server_time: "2026-11-18T00:00:00Z",
    },
    remaining: null,
    finished: false,
    error: null,
    apply: undefined,
    refresh: vi.fn(),
  }),
}));

import ExamPage from "../pages/ExamPage";
import SetupPage from "../pages/SetupPage";

function render(path: string, pattern: string, page: JSX.Element): string {
  return renderToString(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path={pattern} element={page} />
      </Routes>
    </MemoryRouter>,
  );
}

// renderToString 은 따옴표를 &#x27; 로 바꾼다 — 따옴표 없는 핵심 구절로 본다.
const KEY = [
  "Windows 설치 파일 내려받기",
  "href=\"https://github.com/sandcorporation/infralab/releases/latest\"",
  "Windows의 PC 보호", "추가 정보", "실행", "서명 인증서가 없는 설치 파일"];

describe("Windows 설치 파일 링크와 SmartScreen 안내", () => {
  it("설치 안내 화면에 설치 파일 링크와 안내가 있고 compose.yml 길도 남는다", () => {
    const html = render("/cohorts/1/setup", "/cohorts/:id/setup", <SetupPage />);
    expect(html).toContain("compose.yml 내려받기");
    for (const k of KEY) expect(html).toContain(k);
  });

  it("응시 안내·동의 화면에 있다", () => {
    const html = render("/exam/t", "/exam/:token", <ExamPage />);
    expect(html).toContain("위 안내를 읽었고 동의합니다");
    expect(html).toContain("설치 프로그램의 compose.yml 주소에 붙여 넣기");
    expect(html).toContain("/api/exam/t/compose.yml");
    for (const k of KEY) expect(html).toContain(k);
  });
});
