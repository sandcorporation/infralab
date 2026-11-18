// #100(PR) 회귀: 숨은 검사를 켠 시험 회차를 끝까지 치르면 마감 뒤 응시 화면(/exam/<토큰>)이 숨은 검사를 돌려 결과를
// 서버에 올리고, 「채점 마무리 중」을 거쳐 「제출 완료」가 된다. 숨은 검사는 e2e 견본 문제은행(web/e2e/fixtures/problems)에 있다.
import { expect, test } from "@playwright/test";
import { backToExamPage, createExamCohort, finishAttempt, headBadge, inviteRow, issueInvite, openScenario, prepareEnvironment, startAttempt } from "./flows";
import { freshWorkDir } from "./stack";

// 준비한 /work 를 다음 시험(prepare-mark: 처음엔 「준비됨」 없음)에 남기지 않는다 — workstation 은 시험끼리 함께 쓴다.
test.afterEach(() => freshWorkDir());

test("숨은 검사 켠 시험: 제출하고 끝내기 → 「채점 마무리 중」 → 「제출 완료」, 숨은 검사 결과가 서버에 올라간다", async ({ browser }) => {
  const cohort = await createExamCohort(browser, { hiddenChecks: true });
  const label = "숨은 검사 지원자";
  const candidate = await startAttempt(browser, await issueInvite(cohort, label));
  const page = candidate.page;
  await openScenario(candidate);
  await prepareEnvironment(candidate);

  // 마감 뒤 숨은 검사는 응시 화면이 돌린다 — 상단 띠의 회차 이름으로 돌아가 거기서 끝낸다.
  await backToExamPage(candidate);

  // 「채점 마무리 중」이 눈에 보이도록 결과 업로드만 잠깐 붙든다(요청은 그대로 서버로 간다).
  await page.route("**/api/exam/*/final-results", async (route) => {
    await new Promise((r) => setTimeout(r, 1_500));
    await route.continue();
  });
  const uploaded = page.waitForResponse((r) => r.url().endsWith("/final-results") && r.request().method() === "POST", {
    timeout: 60_000,
  });

  await finishAttempt(candidate);
  await expect(headBadge(page)).toHaveText("마감");
  await expect(page.getByRole("status").filter({ hasText: "채점 마무리 중" })).toBeVisible({ timeout: 30_000 });
  expect((await uploaded).status()).toBe(204);
  await expect(page.getByRole("status").filter({ hasText: "제출 완료" })).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText("채점 마무리 중")).toHaveCount(0);
  await expect(page.getByText("채점을 마무리하지 못했습니다")).toHaveCount(0);

  // 서버: 숨은 검사 결과가 올라와 담당자 보고서가 숨은 검사 1/1 을 낸다(업로드를 되돌리면 pending 에 머문다).
  const p = cohort.instructor;
  await p.reload();
  const row = inviteRow(p, label);
  await expect(row.getByText("끝남")).toBeVisible();
  await row.getByRole("link", { name: label }).click();
  await p.waitForURL(/\/exam-invites\/(\d+)\/report$/);
  const inviteId = /exam-invites\/(\d+)\/report/.exec(p.url())![1];
  const res = await p.request.get(`/api/instructor/cohorts/${cohort.cohortId}/exam-invites/${inviteId}/report`);
  expect(res.status(), await res.text()).toBe(200);
  const { score } = (await res.json()) as { score: { hidden_status: string; hidden_passed: number; hidden_total: number } };
  expect(score).toMatchObject({ hidden_status: "done", hidden_passed: 1, hidden_total: 1 });
  await candidate.ctx.close();
});
