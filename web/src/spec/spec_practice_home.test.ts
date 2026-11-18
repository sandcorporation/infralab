// target: web/src/spec/spec_practice_home.test.ts
// AC: #133: `/` 진입 규칙 — 「내 기수」 목록(연습 묶음은 들어 있지 않다)이 비었으면 연습 화면으로, 하나라도 있으면 「내 기수」
//
// 첫 화면이 연습 화면으로 갈지 정하는 순수 함수(web/src/practice.ts 의 shouldOpenPractice)를 본다. 입력은
// GET /api/cohorts 의 결과이고 backend 가 연습 묶음을 빼고 준다(#132). 실제 이동·상단 「연습」·「연습 시작」은 「손 확인」.
import { describe, expect, it } from "vitest";
import type { MyCohort } from "../api";
import { shouldOpenPractice } from "../practice";

const klass: MyCohort = { id: 3, name: "1기", archived: false, joined_at: "2026-11-01T00:00:00Z" };
const archived: MyCohort = { id: 4, name: "0기", archived: true, joined_at: "2026-03-01T00:00:00Z" };

describe("첫 화면 진입 규칙", () => {
  it.skip("속한 수업·시험 묶음이 없으면 연습 화면으로 간다", () => { // #133
    expect(shouldOpenPractice([])).toBe(true);
  });

  it.skip("묶음이 하나라도 있으면 지금처럼 「내 기수」다", () => { // #133
    expect(shouldOpenPractice([klass])).toBe(false);
    expect(shouldOpenPractice([archived])).toBe(false);
    expect(shouldOpenPractice([klass, archived])).toBe(false);
  });
});
