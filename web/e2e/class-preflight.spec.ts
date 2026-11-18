// 수업 묶음 화면의 실습 환경 점검(PR #104): 환경이 안 켜져 있어도 경고만 보이고 수업 흐름(시나리오 화면)은 막히지 않는다.
// 응시 시작이 막히는 시험 회차(`exam-flow.spec.ts`)와 다르다.
import { expect, test } from "@playwright/test";
import { joinClassCohort, newInstructor, newStudent, SCENARIO_ID, SCENARIO_TITLE } from "./flows";
import { agentTokenFor, baseOrigin, startAgent, stopAgent } from "./stack";

test("수업 묶음: 에이전트를 내린 채 열면 경고만 보이고 시나리오 화면은 열리며, 에이전트를 올리고 다시 열면 경고가 사라진다", async ({ browser }) => {
  const instructor = await newInstructor(browser);
  const { ctx, page } = await newStudent(browser, "수업생");
  const className = await joinClassCohort(instructor, page);
  const mine = (await (await page.request.get("/api/cohorts")).json()) as { id: number; name: string }[];
  const cohortId = mine.find((c) => c.name === className)!.id;
  const open = await instructor.request.put(`/api/instructor/cohorts/${cohortId}/scenarios`, {
    data: { scenario_ids: [SCENARIO_ID] },
    headers: { Origin: baseOrigin() },
  });
  expect(open.status(), await open.text()).toBe(200);

  // 에이전트가 꺼져 있다 — 경고(설치 안내)만 보이고 시작을 막는 것은 없다.
  stopAgent();
  await page.goto(`/cohorts/${cohortId}`);
  await expect(page.locator(".sc-badge--danger", { hasText: "에이전트 없음" })).toBeVisible();
  await expect(page.getByText("에이전트가 응답하지 않습니다.")).toBeVisible();
  await expect(page.getByRole("link", { name: "설치 안내", exact: true })).toBeVisible();

  // 수업 흐름은 그대로: 시나리오 화면이 열린다.
  await page.getByRole("link", { name: SCENARIO_TITLE }).click();
  await page.waitForURL(new RegExp(`/cohorts/${cohortId}/scenarios/${SCENARIO_ID}$`));
  await expect(page.getByRole("heading", { name: SCENARIO_TITLE })).toBeVisible();

  // 에이전트를 올리고 다시 열면 경고가 사라지고 점검 통과 안내가 보인다.
  await startAgent(page.request, await agentTokenFor(page, cohortId));
  await page.goto(`/cohorts/${cohortId}`);
  await expect(page.locator(".sc-badge--success", { hasText: "에이전트 연결됨" })).toBeVisible();
  await expect(page.getByText(/응시 전 점검 통과/)).toBeVisible();
  await expect(page.getByText("에이전트가 응답하지 않습니다.")).toHaveCount(0);
  await expect(page.getByRole("alert")).toHaveCount(0);
  await ctx.close();
  await instructor.context().close();
});
