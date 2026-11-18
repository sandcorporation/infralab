import { renderToString } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import type { ExamInvite, ExamScore } from "../api";
import { FinalLabel } from "../pages/InstructorExamReportPage";
import { InviteRow } from "./ExamPanel";

vi.stubGlobal("location", { origin: "http://127.0.0.1" });

const base: ExamInvite = {
  id: 9,
  label: "지원자 A",
  token: "tok",
  status: "finished",
  created_at: "2026-11-18T00:00:00Z",
  started_at: "2026-11-18T01:00:00Z",
  finished_at: "2026-11-18T02:00:00Z",
  event_count: 0,
};

function row(status: ExamInvite["status"]): string {
  return renderToString(
    <MemoryRouter>
      <table>
        <tbody>
          <InviteRow
            cohortId={3}
            invite={{ ...base, status }}
            copied={false}
            busy={false}
            onCopy={() => {}}
            onRevoke={() => {}}
            onEvents={() => {}}
          />
        </tbody>
      </table>
    </MemoryRouter>,
  );
}

describe("응시 링크 표 한 줄", () => {
  it("끝난 응시: 「회수」 없음, 이름은 보고서 링크, 상태 「끝남」", () => {
    const html = row("finished");
    expect(html).not.toContain("회수");
    expect(html).toContain('<a href="/instructor/cohorts/3/exam-invites/9/report">지원자 A</a>');
    expect(html).toContain("끝남");
  });

  it("끝나기 전(발급·진행 중)은 「회수」가 있다", () => {
    expect(row("invited")).toContain("회수");
    expect(row("in_progress")).toContain("회수");
  });
});

describe("보고서 최종 점수 라벨", () => {
  const score: ExamScore = {
    public_passed: 3,
    public_total: 4,
    hidden_passed: 1,
    hidden_total: 2,
    hidden_status: "done",
    final_percent: 67,
  };

  it("「최종(검사)」 + 툴팁에 계산식", () => {
    const html = renderToString(<FinalLabel score={score} />);
    expect(html).toContain("최종(검사)");
    expect(html).toContain("(공개 3 + 숨은 1) ÷ (공개 4 + 숨은 2)");
    expect(html).toContain("루브릭 제외");
  });
});
