import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { PracticeStart } from "./PracticePage";

describe("연습 화면 — 참여 전", () => {
  it("본문에 시나리오 수와 「연습 시작」 단추", () => {
    const html = renderToString(<PracticeStart scenarioCount={7} busy={false} error={null} onStart={() => {}} />);
    expect(html).toContain("연습");
    expect(html).toMatch(/시나리오<\/dt><dd class="sc-stat-value">7</);
    expect(html).toMatch(/<section class="practice-start">[\s\S]*<button[^>]*>연습 시작<\/button>/);
  });

  it("시작하는 중이면 단추가 잠긴다", () => {
    const html = renderToString(<PracticeStart scenarioCount={7} busy error={null} onStart={() => {}} />);
    expect(html).toMatch(/<button disabled="">시작하는 중…<\/button>/);
  });
});
