// 연습 화면 길(PR #142): 묶음 없는 새 계정의 `/`, 「연습 시작」, agent 꺼짐, 상단 「연습」 길, 로그아웃 뒤 `/`.
// 연습 시나리오는 e2e 시나리오(SCENARIOS_DIR 의 e2e-prepare)다.
import { expect, test } from "@playwright/test";
import { joinClassCohort, newInstructor, newStudent, practiceRow, SCENARIO_TITLE, startPractice } from "./flows";
import { agentTokenFor, startAgent, stopAgent } from "./stack";

test("묶음 없는 새 계정의 `/` 는 연습 화면, 「연습 시작」 → 시나리오 목록·상태·설치 안내, 새로 고침 뒤에도 같다", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await page.goto("/");
  await page.waitForURL(/\/practice$/);
  await expect(page.getByRole("heading", { name: "연습" })).toBeVisible();
  await page.getByRole("button", { name: "연습 시작" }).click();

  const expectJoined = async () => {
    await expect(practiceRow(page)).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "시나리오" })).toBeVisible();
    await expect(page.locator(".sc-page-head .sc-badge").first()).toBeVisible(); // 에이전트 상태 배지
    await expect(page.getByRole("link", { name: "설치 안내 · compose.yml" })).toBeVisible();
    await expect(page.getByRole("button", { name: "연습 시작" })).toHaveCount(0);
  };
  await expectJoined();
  await page.reload();
  await expect(page).toHaveURL(/\/practice$/);
  await expectJoined();

  // 참여한 뒤에는 `/` 도 같은 연습 화면으로 간다.
  await page.goto("/");
  await page.waitForURL(/\/practice$/);
  await expectJoined();
  await ctx.close();
});

test("실습 환경(agent)이 꺼져 있어도 연습 시나리오 화면이 열린다", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  stopAgent();
  await startPractice(page);
  await expect(page.locator(".sc-badge--danger", { hasText: "에이전트 없음" })).toBeVisible();
  await expect(page.getByText("에이전트가 응답하지 않습니다.")).toBeVisible();
  await expect(page.getByRole("link", { name: "설치 안내", exact: true })).toBeVisible();

  await page.getByRole("link", { name: SCENARIO_TITLE }).click();
  await page.waitForURL(/\/cohorts\/\d+\/scenarios\/e2e-prepare$/);
  await expect(page.getByRole("heading", { name: SCENARIO_TITLE })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "이동 경로" }).getByRole("link", { name: "연습" })).toBeVisible();
  await ctx.close();
});

test("agent 가 켜져 있으면 연습 화면 상태가 「에이전트 연결됨」", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await startPractice(page);
  const cohortId = Number(/cohorts\/(\d+)/.exec((await practiceRow(page).getByRole("link").getAttribute("href"))!)![1]);
  await startAgent(page.request, await agentTokenFor(page, cohortId));
  await page.reload();
  await expect(page.locator(".sc-badge--success", { hasText: "에이전트 연결됨" })).toBeVisible();
  await ctx.close();
});

test("상단 「연습」 길로 연습 화면에 가고, 수업 묶음에 든 계정의 `/` 는 수업 쪽(내 기수)이다", async ({ browser }) => {
  const instructor = await newInstructor(browser);
  const { ctx, page } = await newStudent(browser, "수업생");
  const className = await joinClassCohort(instructor, page);

  // 수업 묶음이 있으면 `/` 는 연습으로 가지 않고 「내 기수」 표다.
  await page.goto("/");
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole("heading", { name: "내 기수" })).toBeVisible();
  await expect(page.getByRole("link", { name: className })).toBeVisible();

  // 상단 「연습」 길 — 참여 전이면 「연습 시작」.
  await page.getByRole("navigation", { name: "주 메뉴" }).getByRole("link", { name: "연습" }).click();
  await page.waitForURL(/\/practice$/);
  await page.getByRole("button", { name: "연습 시작" }).click();
  await expect(practiceRow(page)).toBeVisible();

  // 연습에 참여해도 `/` 는 여전히 수업 쪽이다.
  await page.getByRole("navigation", { name: "주 메뉴" }).getByRole("link", { name: "내 기수" }).click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole("link", { name: className })).toBeVisible();
  await ctx.close();
  await instructor.context().close();
});

test("로그아웃 뒤 `/` 는 로그인 화면(로그인 버튼)이고, 연습 화면은 로그인 없이 열리지 않는다", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await startPractice(page);
  await page.getByRole("button", { name: /연습생/ }).click();
  await page.getByRole("menuitem", { name: "로그아웃" }).click();

  await page.goto("/");
  await page.waitForURL(/\/login$/);
  await expect(page.getByRole("heading", { name: "로그인" })).toBeVisible();
  await expect(page.getByRole("button", { name: "로그인", exact: true })).toBeVisible();
  await page.goto("/practice");
  await page.waitForURL(/\/login$/);
  await ctx.close();
});
