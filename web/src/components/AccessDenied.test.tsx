import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AccessDeniedView } from "./AccessDenied";
import { safeNext } from "../pages/LoginPage";

describe("강사 화면 거절", () => {
  it("응시 세션: 상태 + 로그아웃하고 내 계정으로 로그인", () => {
    const html = renderToString(<AccessDeniedView examSession busy={false} onSwitch={() => {}} />);
    expect(html).toContain("응시 세션으로 들어와 있습니다");
    expect(html).toMatch(/<button[^>]*>로그아웃하고 내 계정으로 로그인<\/button>/);
  });

  it("강사 아닌 일반 사용자도 계정 전환 길", () => {
    const html = renderToString(<AccessDeniedView examSession={false} busy={false} onSwitch={() => {}} />);
    expect(html).toContain("강사만 볼 수 있는 화면입니다");
    expect(html).toMatch(/<button[^>]*>로그아웃하고 다른 계정으로 로그인<\/button>/);
  });
});

describe("로그인 ?next=", () => {
  it("이 사이트 안 경로만 받는다", () => {
    expect(safeNext("/instructor/cohorts/2?tab=a")).toBe("/instructor/cohorts/2?tab=a");
    expect(safeNext("//evil.example")).toBeNull();
    expect(safeNext("https://evil.example")).toBeNull();
    expect(safeNext(null)).toBeNull();
  });
});
