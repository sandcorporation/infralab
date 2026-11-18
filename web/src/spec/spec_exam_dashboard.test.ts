// target: web/src/spec/spec_exam_dashboard.test.ts
// AC: #77: 웹 — 구간 막대 높이는 가장 큰 구간 대비 비율로 그린다(빈 회차는 모두 0)
//
// 시험 대시보드의 분포 막대가 쓰는 순수 함수(web/src/exam.ts 의 bucketHeights)를 본다. 막대가 실제로 그려지는
// 모습은 티켓의 「손 확인」이다.
import { describe, expect, it } from "vitest";
import { bucketHeights } from "../exam";

describe("점수 분포 막대", () => {
  it("가장 큰 구간을 1 로 두고 나머지는 그 비율이다", () => {
    expect(bucketHeights([2, 4, 0, 1, 0])).toEqual([0.5, 1, 0, 0.25, 0]);
    expect(bucketHeights([0, 0, 3, 0, 0])).toEqual([0, 0, 1, 0, 0]);
  });

  it("빈 회차는 모두 0 이다", () => {
    expect(bucketHeights([0, 0, 0, 0, 0])).toEqual([0, 0, 0, 0, 0]);
  });
});
