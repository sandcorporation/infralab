// 개인 연습 화면의 순수 판단 — 첫 화면 진입 규칙(#133)과 피드백 버튼 상태(#134).
import type { MyCohort } from "./api";

/** `GET /api/cohorts`(연습 묶음은 빠져 있다)가 비었으면 `/` 가 연습 화면으로 간다. */
export function shouldOpenPractice(myCohorts: readonly MyCohort[]): boolean {
  return myCohorts.length === 0;
}

export type FeedbackAction = "show" | "request" | "no_transcript" | "limit_reached";

/** 연습 제출 하나의 결과 아래에 보일 것 — 기존 피드백·「피드백 받기」·다시 제출 안내·한도 소진 안내. */
export function feedbackAction(
  _sub: { has_transcript: boolean; has_feedback: boolean },
  _remaining: number,
): FeedbackAction {
  throw new Error("#134");
}
