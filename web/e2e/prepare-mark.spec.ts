// #124(PR #127) 회귀: 시나리오 「준비됨」 표시는 준비한 /work 에 붙는다.
// 옛 버그 — 표시가 홈 볼륨(/root/.infralab)에 써져, 같은 홈을 쓰는 다른 기수 폴더(빈 /work)에서도 「준비됨」이 떴다.
// 실제 에이전트가 docker exec 로 workstation 안에서 setup 을 돌리고 표시를 쓴다.
import { expect, test } from "@playwright/test";
import { createExamCohort, issueInvite, openScenario, SCENARIO_ID, startAttempt } from "./flows";
import { freshWorkDir, inWorkstation } from "./stack";

test("환경 준비 → 「준비됨」, 새 /work(같은 홈)로 바꾸면 「준비됨」이 사라지고 다시 준비할 수 있다", async ({ browser }) => {
  const cohort = await createExamCohort(browser);
  const candidate = await startAttempt(browser, await issueInvite(cohort, "준비 지원자"));
  const page = candidate.page;
  await openScenario(candidate);

  const prepared = page.locator(".sc-badge--success", { hasText: "준비됨" });
  await expect(prepared).toHaveCount(0);
  await page.getByRole("button", { name: "환경 준비", exact: true }).click();
  await page.getByRole("button", { name: "환경 준비 확정" }).click();
  await expect(prepared).toBeVisible({ timeout: 60_000 });
  expect(inWorkstation("cat", "/work/app/ready.txt").trim()).toBe("ready");
  expect(inWorkstation("ls", "/work/.infralab")).toContain(`${SCENARIO_ID}.prepared`);

  // 준비한 환경을 채점·제출한다(PR #96) — 검사가 workstation 안에서 돌아 1/1, 서버에 제출됨.
  await page.getByRole("button", { name: "채점", exact: true }).click();
  await expect(page.locator(".score")).toHaveText("1/1", { timeout: 30_000 });
  await expect(page.getByText(/^제출됨/)).toBeVisible();

  // 다른 기수 폴더: /work 만 새것, 홈 볼륨은 그대로.
  freshWorkDir();
  await page.reload();
  await expect(page.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "환경 준비", exact: true })).toBeVisible();
  await expect(prepared).toHaveCount(0);
  await candidate.ctx.close();
});
