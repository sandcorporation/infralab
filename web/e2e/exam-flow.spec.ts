// 시험 응시 흐름 한 바퀴 — 강사(회차·설정·링크) → 응시자(링크·점검·시작) → 감독 신호(탭 바꾸기·붙여넣기)
// → 제출하고 끝내기 → 강사 화면 「끝남」·보고서 감독 탭. PR #93·#96·#101·#104 의 사람 확인 항목을 옮겼다.
import { expect, test } from "@playwright/test";
import { createExamCohort, headBadge, inviteRow, issueInvite, openScenario, startAttempt } from "./flows";
import { pasteIntoTerminal } from "./terminal";

test("응시 흐름: 시작 → 응시 중 → 탭 이탈·붙여넣기 신호 → 제출하고 끝내기 → 끝남·보고서", async ({ browser }) => {
  const cohort = await createExamCohort(browser);
  const label = "흐름 지원자";
  const candidate = await startAttempt(browser, await issueInvite(cohort, label));
  const page = candidate.page;

  // 응시 중: 상단 띠의 남은 시간이 흐르고, 새로 고침해도 같은 응시로 이어진다.
  const remaining = page.locator(".exam-bar");
  await expect(remaining).toContainText("남은 시간");
  const clock = page.locator(".exam-clock");
  const first = await clock.textContent();
  await expect(clock).not.toHaveText(first ?? "", { timeout: 3_000 });
  await page.reload();
  await expect(headBadge(page)).toHaveText("응시 중");

  const p = cohort.instructor;
  await p.reload();
  await expect(inviteRow(p, label).getByText("응시 중")).toBeVisible();

  // 탭 바꾸기: 다른 탭을 앞으로 가져왔다가 돌아온다.
  const other = await candidate.ctx.newPage();
  await other.bringToFront();
  await page.bringToFront();
  await other.close();

  await openScenario(candidate);
  await pasteIntoTerminal(page, "echo flow-paste");

  // 제출하고 끝내기 — 확인을 거쳐 마감.
  await page.getByRole("button", { name: "제출하고 끝내기" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "끝내기", exact: true }).click();
  await expect(remaining).toContainText("마감");

  // 강사: 「끝남」, 감독 신호 건수, 보고서 감독 탭에 두 신호가 시각 순으로.
  await p.reload();
  const row = inviteRow(p, label);
  await expect(row.getByText("끝남")).toBeVisible();
  await row.getByRole("link", { name: label }).click();
  await p.waitForURL(/\/exam-invites\/\d+\/report$/);
  await p.getByRole("tab", { name: /감독/ }).click();
  const events = p.locator("ol.events li");
  await expect(events.filter({ hasText: "탭 이탈" })).toHaveCount(1);
  await expect(events.filter({ hasText: "붙여넣기" })).toHaveCount(1);
  const texts = await events.allTextContents();
  expect(texts.findIndex((t) => t.includes("탭 이탈"))).toBeLessThan(texts.findIndex((t) => t.includes("붙여넣기")));
  await candidate.ctx.close();
});

test("회수한 응시 링크: 강사 표에 「회수됨」, 그 링크로는 들어올 수 없다", async ({ browser }) => {
  const cohort = await createExamCohort(browser);
  const label = "회수 지원자";
  const examPath = await issueInvite(cohort, label);
  const p = cohort.instructor;
  const row = inviteRow(p, label);
  await row.getByRole("button", { name: "회수" }).click();
  await p.getByRole("dialog").getByRole("button", { name: "회수", exact: true }).click();
  await expect(row.getByText("회수됨")).toBeVisible();

  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto(examPath);
  await expect(page.getByText("응시 링크가 올바르지 않거나 회수되었습니다.")).toBeVisible();
  await ctx.close();
});
