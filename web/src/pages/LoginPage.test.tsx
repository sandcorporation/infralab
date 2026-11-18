import { renderToString } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../auth", () => ({ useAuth: () => ({ me: null, login: vi.fn() }) }));

import LoginPage from "./LoginPage";

function render(path = "/login"): string {
  return renderToString(
    <MemoryRouter initialEntries={[path]}>
      <LoginPage />
    </MemoryRouter>,
  );
}

afterEach(() => vi.unstubAllEnvs());

describe("로그인 화면", () => {
  it("운영 모드 → Sandcorp 계정 버튼만, 개발용 폼 없음", () => {
    vi.stubEnv("DEV", false);
    const html = render();
    expect(html).toContain("Sandcorp 계정으로 로그인");
    expect(html).not.toContain("개발용 로그인");
    expect(html).not.toContain("<form");
    expect(html).not.toContain("카카오");
  });

  it("개발 모드 → 개발용 폼", () => {
    vi.stubEnv("DEV", true);
    const html = render();
    expect(html).toContain("개발용 로그인");
    expect(html).toContain("<form");
  });

  it("?error=1 이면 오류 한 줄", () => {
    vi.stubEnv("DEV", false);
    expect(render("/login?error=1")).toContain("로그인하지 못했습니다");
    expect(render("/login")).not.toContain("로그인하지 못했습니다");
  });
});
