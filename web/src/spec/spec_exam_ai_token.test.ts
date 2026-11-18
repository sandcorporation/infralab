// target: web/src/spec/spec_exam_ai_token.test.ts
// AC: #72: 웹 — 응시 화면의 「AI 키 설정」 칸이 env 를 export K="V" 줄로 보여 주고 복사할 수 있다
//
// 「AI 키 설정」 칸이 쓰는 함수(web/src/exam.ts)를 본다: env 를 터미널에 붙여 넣을 export 줄로 바꾸기(셸이 값을
// 바꾸지 않게 따옴표 안의 특수 문자를 이스케이프)와 설정을 받는 요청. 복사 버튼과 실제 터미널은 「손 확인」.
import { afterEach, describe, expect, it, vi } from "vitest";
import { envExportText, getAiConfig } from "../exam";
import type { AiConfig } from "../exam";

afterEach(() => vi.unstubAllGlobals());

describe("AI 키 설정", () => {
  it.skip("env 를 키 순서대로 export 줄로 잇는다", () => { // #72
    const text = envExportText({
      ANTHROPIC_BASE_URL: "https://proxy.infralab.test/anthropic",
      ANTHROPIC_AUTH_TOKEN: "tok-1",
      ANTHROPIC_MODEL: "claude-sonnet-4-5",
    });
    expect(text).toBe(
      [
        'export ANTHROPIC_BASE_URL="https://proxy.infralab.test/anthropic"',
        'export ANTHROPIC_AUTH_TOKEN="tok-1"',
        'export ANTHROPIC_MODEL="claude-sonnet-4-5"',
      ].join("\n"),
    );
    expect(text.endsWith("\n")).toBe(false);
  });

  it.skip("값 안의 따옴표·역슬래시·달러·백틱은 이스케이프한다", () => { // #72
    expect(envExportText({ K: 'a"b\\c$d`e' })).toBe('export K="a\\"b\\\\c\\$d\\`e"');
  });

  it.skip("빈 env 는 빈 글이다", () => { // #72
    expect(envExportText({})).toBe("");
  });

  it.skip("설정은 응시 토큰의 ai-config 에서 받는다", async () => { // #72
    const config: AiConfig = {
      proxy_url: "https://proxy.infralab.test",
      token: "tok-1",
      tools: [
        {
          tool: "claude_code",
          model: "claude-sonnet-4-5",
          env: { ANTHROPIC_AUTH_TOKEN: "tok-1" },
          config_toml: "",
        },
      ],
    };
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(config), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const out = await getAiConfig("inv123");

    expect(out).toEqual(config);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit | undefined];
    expect(path).toBe("/api/exam/inv123/ai-config");
    expect(init?.method ?? "GET").toBe("GET");
  });
});
