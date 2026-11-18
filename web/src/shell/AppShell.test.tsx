import { renderToString } from "react-dom/server";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

const auth = vi.hoisted(() => ({
  me: null as null | { id: number; username: string; display_name: string; is_instructor: boolean; orgs: [] },
}));
vi.mock("../auth", () => ({ useAuth: () => ({ me: auth.me, logout: vi.fn() }) }));

import { AppShell, currentNavItem, navGroups } from "./AppShell";
import { cohortTabs } from "../pages/InstructorCohortPage";

const INSTRUCTOR = { id: 1, username: "kim", display_name: "김강사", is_instructor: true, orgs: [] as [] };
const STUDENT = { ...INSTRUCTOR, display_name: "이학생", is_instructor: false };

function render(path: string): string {
  return renderToString(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<AppShell />}>
          <Route path="*" element={<p>본문</p>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  );
}

/** 사이드바 링크 이름 → aria-current 여부. */
function navLinks(html: string): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const m of html.matchAll(/<a[^>]*class="sc-sidenav-item[^"]*"[^>]*>.*?<span class="sc-sidenav-label">([^<]+)<\/span><\/a>/g))
    out[m[1]] = /aria-current="page"/.test(m[0]);
  return out;
}

describe("사이드바 내비", () => {
  it("강사는 강사 묶음(기수·시험·조직)과 학생 묶음(내 기수·연습)", () => {
    const groups = navGroups(INSTRUCTOR);
    expect(groups.map((g) => g.heading)).toEqual(["강사", "학생"]);
    expect(groups[0].items.map((i) => i.label)).toEqual(["기수", "시험", "조직"]);
    expect(groups[1].items.map((i) => i.label)).toEqual(["내 기수", "연습"]);
  });

  it("학생에겐 강사 묶음이 없다", () => {
    expect(navGroups(STUDENT).map((g) => g.heading)).toEqual(["학생"]);
  });

  it.each([
    ["/instructor", "기수"],
    ["/instructor/cohorts/3", "기수"],
    ["/instructor/cohorts/3/students", "기수"],
    ["/instructor/cohorts/3/exam-invites/9/report", "기수"],
    ["/instructor/exams", "시험"],
    ["/instructor/org", "조직"],
    ["/", "내 기수"],
    ["/cohorts/4/scenarios/vpc-basics", "내 기수"],
    ["/practice", "연습"],
    ["/practice/records/k8s-basics", "연습"],
    ["/instructor/exams/3", "시험"],
    ["/instructor/org/invites", "조직"],
    ["/cohorts/4/setup", "내 기수"],
  ])("%s → 현재 위치는 %s", (path, label) => {
    expect(currentNavItem(navGroups(INSTRUCTOR), path)?.label).toBe(label);
  });

  it("현재 위치 하나만 aria-current 로 칠한다", () => {
    auth.me = INSTRUCTOR;
    expect(navLinks(render("/instructor/cohorts/3/settings"))).toEqual({
      기수: true,
      시험: false,
      조직: false,
      "내 기수": false,
      연습: false,
    });
    expect(navLinks(render("/instructor/org"))).toEqual({ 기수: false, 시험: false, 조직: true, "내 기수": false, 연습: false });
    expect(navLinks(render("/practice"))).toEqual({ 기수: false, 시험: false, 조직: false, "내 기수": false, 연습: true });
    // 하위 경로에서도 가장 구체적인 한 항목만 — NavLink 의 앞부분 일치로 「기수」「내 기수」가 같이 켜지던 것(#147).
    for (const [path, label] of [
      ["/instructor/exams/3", "시험"],
      ["/instructor/org/invites", "조직"],
      ["/instructor/cohorts/3/invites", "기수"],
      ["/practice/records/k8s-basics", "연습"],
      ["/cohorts/4/scenarios/vpc-basics", "내 기수"],
    ]) {
      const on = Object.entries(navLinks(render(path))).filter(([, v]) => v).map(([k]) => k);
      expect(on, path).toEqual([label]);
    }
  });

  it("로그인 사용자는 sc-app 골격(사이드바 + 상단 바 + 휴대폰 메뉴 단추 + 계정 메뉴)", () => {
    auth.me = STUDENT;
    const html = render("/");
    expect(html).toContain('class="sc-app"');
    expect(html).toContain('class="sc-sidenav"');
    expect(html).toContain('class="sc-topbar"');
    expect(html).toMatch(/aria-controls="app-sidenav"[^>]*>|aria-label="메뉴 열기"/);
    expect(html).toContain('aria-haspopup="menu"');
    expect(html).toContain("이학생");
  });

  it("로그인 전과 응시 화면은 사이드바 없이", () => {
    auth.me = null;
    expect(render("/login")).not.toContain("sc-sidenav");
    auth.me = STUDENT;
    expect(render("/exam/abc")).not.toContain("sc-sidenav");
    auth.me = { ...STUDENT, username: "exam-invite:7" };
    expect(render("/cohorts/1")).not.toContain("sc-sidenav");
  });
});

describe("기수 상세 탭", () => {
  const base = { id: 5, member_count: 12, open_scenario_ids: ["a", "b"] };

  it("수업: 개요·시나리오·학생·진행·설정 (응시 링크 없음), 경로는 하위 경로", () => {
    const tabs = cohortTabs({ ...base, kind: "class" });
    expect(tabs.map((t) => t.label)).toEqual(["개요", "시나리오", "학생", "진행", "설정"]);
    expect(tabs.map((t) => t.to)).toEqual([
      "/instructor/cohorts/5",
      "/instructor/cohorts/5/scenarios",
      "/instructor/cohorts/5/students",
      "/instructor/cohorts/5/grid",
      "/instructor/cohorts/5/settings",
    ]);
    expect(tabs[0].end).toBe(true);
    expect(tabs.find((t) => t.label === "학생")?.count).toBe(12);
    expect(tabs.find((t) => t.label === "시나리오")?.count).toBe(2);
  });

  it("시험: 응시 링크 탭이 설정 앞에", () => {
    const tabs = cohortTabs({ ...base, kind: "exam" });
    expect(tabs.map((t) => t.label)).toEqual(["개요", "시나리오", "학생", "진행", "응시 링크", "설정"]);
    expect(tabs[4].to).toBe("/instructor/cohorts/5/invites");
  });
});
