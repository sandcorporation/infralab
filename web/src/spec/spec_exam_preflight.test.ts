// target: web/src/spec/spec_exam_preflight.test.ts
// AC: #78: 웹 — 시험에서는 점검 실패·agent 미응답이면 시작할 수 없고, 연습에서는 시작할 수 있되 경고가 남는다
//
// 응시 화면과 연습 화면이 「시작」 버튼을 열지 정하는 순수 함수(web/src/exam.ts 의 preflightGate)를 본다.
// 점검 결과는 agent GET /api/preflight 의 응답이고, agent 에 닿지 못하면 null 이다. 실제 버튼·안내 링크는 「손 확인」.
import { describe, expect, it } from "vitest";
import { preflightGate } from "../exam";
import type { Preflight } from "../exam";

const passing: Preflight = {
  ok: true,
  checks: [
    { id: "engine", ok: true, message: "Docker 엔진이 돈다", help_url: "" },
    { id: "linux_mode", ok: true, message: "Linux 컨테이너 모드", help_url: "" },
    { id: "permission", ok: true, message: "docker 권한 있음", help_url: "" },
  ],
};

const windowsMode: Preflight = {
  ok: false,
  checks: [
    { id: "engine", ok: true, message: "Docker 엔진이 돈다", help_url: "" },
    { id: "linux_mode", ok: false, message: "Windows 컨테이너 모드다 — Linux 컨테이너로 바꾼다", help_url: "https://docs.docker.com/desktop/" },
    { id: "permission", ok: true, message: "docker 권한 있음", help_url: "" },
  ],
};

describe("응시 전 점검", () => {
  it.skip("모두 통과면 시험도 연습도 경고 없이 시작한다", () => { // #78
    expect(preflightGate(passing, "exam")).toEqual({ canStart: true, warnings: [] });
    expect(preflightGate(passing, "practice")).toEqual({ canStart: true, warnings: [] });
  });

  it.skip("시험에서는 점검이 실패하면 시작할 수 없고 실패한 항목만 경고한다", () => { // #78
    const gate = preflightGate(windowsMode, "exam");
    expect(gate.canStart).toBe(false);
    expect(gate.warnings).toEqual(["Windows 컨테이너 모드다 — Linux 컨테이너로 바꾼다"]);
  });

  it.skip("연습에서는 점검이 실패해도 시작하되 경고가 남는다", () => { // #78
    const gate = preflightGate(windowsMode, "practice");
    expect(gate.canStart).toBe(true);
    expect(gate.warnings).toEqual(["Windows 컨테이너 모드다 — Linux 컨테이너로 바꾼다"]);
  });

  it.skip("agent 가 응답하지 않으면 시험은 막고 연습은 경고만 한다", () => { // #78
    const exam = preflightGate(null, "exam");
    expect(exam.canStart).toBe(false);
    expect(exam.warnings.length).toBeGreaterThan(0);
    const practice = preflightGate(null, "practice");
    expect(practice.canStart).toBe(true);
    expect(practice.warnings.length).toBeGreaterThan(0);
  });
});
