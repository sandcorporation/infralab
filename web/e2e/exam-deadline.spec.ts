// 마감 뒤: 시간 제한이 지나면 채점이 막히고 「마감」 안내가 나온다(PR #96). 1분을 기다리지 않고
// e2e 전용 관리 명령(e2e_expire_exam, #194)으로 응시의 시작 시각을 당긴다.
import { expect, test } from "@playwright/test";
import { createExamCohort, headBadge, issueInvite, openScenario, startAttempt } from "./flows";
import { expireExam } from "./stack";

test("마감 뒤: 시계를 당기면 채점이 막히고 「마감」 안내가 나온다", async ({ browser }) => {
  const cohort = await createExamCohort(browser);
  const candidate = await startAttempt(browser, await issueInvite(cohort, "마감 지원자"));
  const page = candidate.page;
  await openScenario(candidate);
  await expect(page.locator(".exam-bar")).toContainText("남은 시간");

  expireExam(candidate.cohortId);

  // 시나리오 화면: 띠가 「마감」, 채점 버튼이 막히고 이유가 보인다.
  await page.reload();
  await expect(page.locator(".exam-bar")).toContainText("마감 — 더 제출할 수 없습니다");
  await expect(page.getByRole("button", { name: "채점", exact: true })).toBeDisabled();
  await expect(page.getByText("시험 마감", { exact: true })).toBeVisible();

  // 응시 화면: 머리 배지 「마감」과 마감 안내.
  await page.locator(".exam-bar").getByRole("link").click();
  await page.waitForURL(/\/exam\/[^/]+$/);
  await expect(headBadge(page)).toHaveText("마감");
  await expect(page.getByText("시험이 마감되었습니다.")).toBeVisible();
  await candidate.ctx.close();
});
