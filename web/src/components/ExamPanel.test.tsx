import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { ExamSettings, ExamTool } from "../api";
import { ToolOptions } from "./ExamPanel";

const FORM: ExamSettings = {
  time_limit_minutes: 60,
  tools: [],
  models: {},
  proctoring: false,
  hidden_checks: false,
  ai_token_limit: 0,
};

/** 도구 한 줄씩(라벨 → 그 줄 HTML). */
function render(form: ExamSettings, unavailable: ExamTool[]): Record<string, string> {
  const html = renderToString(<ToolOptions form={form} unavailable={unavailable} onToggle={() => {}} onModel={() => {}} />);
  const rows: Record<string, string> = {};
  for (const row of html.split('<div class="row">').slice(1)) {
    for (const label of ["Claude Code", "Codex", "로컬 LLM"]) if (row.includes(label)) rows[label] = row;
  }
  return rows;
}

const disabled = (row: string) => /<input[^>]*type="checkbox"[^>]*disabled=""/.test(row);
const checked = (row: string) => /<input[^>]*type="checkbox"[^>]*checked=""/.test(row);

describe("시험 설정 허용 도구", () => {
  it("공급사 키가 없는 도구는 비활성 + 「공급사 키 없음」", () => {
    const rows = render(FORM, ["codex"]);
    expect(disabled(rows["Codex"])).toBe(true);
    expect(rows["Codex"]).toContain("공급사 키 없음");
    for (const label of ["Claude Code", "로컬 LLM"]) {
      expect(disabled(rows[label])).toBe(false);
      expect(rows[label]).not.toContain("공급사 키 없음");
    }
  });

  it("모두 설정됐거나 모르면 표시 없음", () => {
    for (const row of Object.values(render(FORM, []))) {
      expect(disabled(row)).toBe(false);
      expect(row).not.toContain("공급사 키 없음");
    }
  });

  it("이미 골라 둔 도구는 키가 없어도 풀 수 있다", () => {
    const rows = render({ ...FORM, tools: ["codex"], models: { codex: "gpt-5-codex" } }, ["codex"]);
    expect(checked(rows["Codex"])).toBe(true);
    expect(disabled(rows["Codex"])).toBe(false);
    expect(rows["Codex"]).toContain("공급사 키 없음");
  });
});
