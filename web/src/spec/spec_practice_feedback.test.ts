// target: web/src/spec/spec_practice_feedback.test.ts
// AC: #134: 웹 — 연습 제출의 결과 아래에 「피드백 받기」(남은 횟수 표시)·기존 피드백 보기·「AI 대화 함께 제출을 켜고 다시 제출하세요」·한도 소진 안내 중 하나를 보인다
//
// 연습 제출 하나에서 무엇을 보일지 정하는 순수 함수(web/src/practice.ts 의 feedbackAction)를 본다. 입력은 제출의
// has_transcript·피드백 유무와 오늘 남은 횟수(GET /api/practice/feedback-quota 의 remaining)다. 글귀·모습은 「손 확인」.
import { describe, expect, it } from "vitest";
import { feedbackAction } from "../practice";

describe("연습 피드백 버튼", () => {
  it.skip("대화 기록이 있고 횟수가 남았으면 「피드백 받기」다", () => { // #134
    expect(feedbackAction({ has_transcript: true, has_feedback: false }, 5)).toBe("request");
    expect(feedbackAction({ has_transcript: true, has_feedback: false }, 1)).toBe("request");
  });

  it.skip("이미 받은 피드백은 남은 횟수와 상관없이 보여 준다", () => { // #134
    expect(feedbackAction({ has_transcript: true, has_feedback: true }, 3)).toBe("show");
    expect(feedbackAction({ has_transcript: true, has_feedback: true }, 0)).toBe("show");
  });

  it.skip("대화 기록이 없으면 버튼 대신 다시 제출 안내다", () => { // #134
    expect(feedbackAction({ has_transcript: false, has_feedback: false }, 5)).toBe("no_transcript");
    expect(feedbackAction({ has_transcript: false, has_feedback: false }, 0)).toBe("no_transcript");
  });

  it.skip("오늘 횟수를 다 썼으면 한도 소진 안내다", () => { // #134
    expect(feedbackAction({ has_transcript: true, has_feedback: false }, 0)).toBe("limit_reached");
    expect(feedbackAction({ has_transcript: true, has_feedback: false }, -1)).toBe("limit_reached");
  });
});
