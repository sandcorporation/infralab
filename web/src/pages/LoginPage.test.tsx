import { renderToString } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";

const kakao = vi.hoisted(() => ({ kakaoEnabled: false, startKakaoLogin: vi.fn() }));
vi.mock("../kakao", () => kakao);
vi.mock("../auth", () => ({ useAuth: () => ({ me: null, login: vi.fn() }) }));

import LoginPage from "./LoginPage";

function render(): string {
  return renderToString(
    <MemoryRouter>
      <LoginPage />
    </MemoryRouter>,
  );
}

afterEach(() => vi.unstubAllEnvs());

describe("로그인 화면", () => {
  it("운영 모드 + 키 없음 → 개발용 폼 없음, 준비 중", () => {
    vi.stubEnv("DEV", false);
    kakao.kakaoEnabled = false;
    const html = render();
    expect(html).not.toContain("개발용 로그인");
    expect(html).not.toContain("<form");
    expect(html).toContain("로그인 준비 중");
  });

  it("운영 모드 + 키 있음 → 카카오 버튼만", () => {
    vi.stubEnv("DEV", false);
    kakao.kakaoEnabled = true;
    const html = render();
    expect(html).toContain("카카오로 로그인");
    expect(html).not.toContain("<form");
    expect(html).not.toContain("준비 중");
  });

  it("개발 모드 + 키 없음 → 개발용 폼", () => {
    vi.stubEnv("DEV", true);
    kakao.kakaoEnabled = false;
    const html = render();
    expect(html).toContain("개발용 로그인");
    expect(html).toContain("<form");
  });
});
