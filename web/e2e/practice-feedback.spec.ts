// 연습 피드백(PR #143)과 내 기록(PR #144). 채점기는 공급사 키 없는 e2e 스택의 가짜 채점기(결정적)다.
// AI 대화는 진짜 AI 없이 workstation 홈(/root/.claude/projects)에 Claude Code 세션 기록을 심어 「AI 대화 함께 제출」로 올린다.
import { expect, test } from "@playwright/test";
import {
  apiFeedback,
  apiSubmit,
  feedbackRemaining,
  GOOD_TURNS,
  gradeAndSubmit,
  joinClassCohort,
  newInstructor,
  newStudent,
  openPracticeScenario,
  plantClaudeSession,
  prepareOnPage,
  SCENARIO_ID,
  SCENARIO_TITLE,
} from "./flows";
import { agentTokenFor, baseOrigin, freshWorkDir, startAgent } from "./stack";

const LABELS = ["문제 나누기", "지시 명확성", "결과 검증", "위험 명령 막기"];
const LIMIT_NOTICE = "오늘 피드백 5회를 다 썼습니다 — 내일 다시";

// 준비한 /work 와 심은 세션 기록을 다음 시험에 남기지 않는다(표시 시각 이후의 기록만 읽히지만 준비 상태는 남는다).
test.beforeEach(() => freshWorkDir());
test.afterEach(() => freshWorkDir());

test("「AI 대화 함께 제출」 → 「피드백 받기」와 남은 횟수 → 네 항목 점수·횟수 하나 줆 → 다시 열어도 같은 피드백(횟수 그대로)", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await openPracticeScenario(page);
  await prepareOnPage(page);
  await plantClaudeSession(GOOD_TURNS);
  const sub = await gradeAndSubmit(page, { attach: true });
  expect(sub.has_transcript).toBe(true);
  await expect(page.getByText("대화 포함")).toBeVisible();

  await expect(page.getByText("오늘 5회 중 5회 남음")).toBeVisible();
  await page.getByRole("button", { name: "피드백 받기" }).click();

  const table = page.locator("table.sc-table", { hasText: "근거 인용" });
  await expect(table).toBeVisible();
  for (const label of LABELS) {
    const row = table.getByRole("row").filter({ hasText: label });
    await expect(row).toBeVisible();
    await expect(row.getByRole("cell").nth(1)).toHaveText(/^[1-5]\/5$/); // 점수 0 이 아니다 — 심은 대화의 문장이 근거로 잡혔다
    await expect(row.locator("blockquote").first()).toBeVisible();
  }
  await expect(page.getByText(/가짜 채점기 · /)).toBeVisible();
  await expect(page.getByRole("button", { name: "피드백 받기" })).toHaveCount(0);
  expect(await feedbackRemaining(page)).toBe(4);
  const first = await table.innerText();
  const api = await (await page.request.get(`/api/practice/submissions/${sub.id}/feedback`)).json();

  // 다시 열기: 새로 고침 뒤 「내 기록」의 같은 제출 — 같은 피드백이고 횟수는 그대로다.
  await page.reload();
  await expect(page.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "내 기록" }).click();
  const history = page.getByRole("tabpanel", { name: "내 기록" });
  await expect(history.getByRole("listitem")).toHaveCount(1);
  await history.getByRole("listitem").getByRole("button").click();
  const reopened = history.locator("table.sc-table", { hasText: "근거 인용" });
  await expect(reopened).toBeVisible();
  expect(await reopened.innerText()).toBe(first);
  expect(await (await page.request.get(`/api/practice/submissions/${sub.id}/feedback`)).json()).toEqual(api);
  expect(await feedbackRemaining(page)).toBe(4);
  await ctx.close();
});

test("대화 없이 낸 제출의 피드백 칸은 다시 제출하라는 안내를 보이고, 피드백 요청은 막힌다", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await openPracticeScenario(page);
  await prepareOnPage(page);
  await plantClaudeSession(GOOD_TURNS); // 대화가 있어도 학생이 끄면 올라가지 않는다
  const sub = await gradeAndSubmit(page, { attach: false });
  expect(sub.has_transcript).toBe(false);
  await expect(page.getByText(/^제출됨/)).not.toContainText("대화 포함");

  await expect(page.getByText("AI 대화 함께 제출을 켜고 다시 제출하세요")).toBeVisible();
  await expect(page.getByRole("button", { name: "피드백 받기" })).toHaveCount(0);
  const res = await page.request.post(`/api/practice/submissions/${sub.id}/feedback`, { headers: { Origin: baseOrigin() } });
  expect(res.status()).toBe(422);
  expect(await feedbackRemaining(page)).toBe(5);
  await ctx.close();
});

test("하루 5회를 다 쓰면 소진 안내가 보인다(앞 4회는 API, 다섯 번째는 화면)", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  const cohortId = await openPracticeScenario(page);
  await prepareOnPage(page);
  for (let i = 0; i < 4; i++) await apiFeedback(page, await apiSubmit(page, cohortId, SCENARIO_ID, "ready-file"));
  expect(await feedbackRemaining(page)).toBe(1);

  await plantClaudeSession(GOOD_TURNS);
  await gradeAndSubmit(page, { attach: true });
  await expect(page.getByText("오늘 5회 중 1회 남음")).toBeVisible();
  await page.getByRole("button", { name: "피드백 받기" }).click();
  await expect(page.locator("table.sc-table", { hasText: "근거 인용" })).toBeVisible();
  expect(await feedbackRemaining(page)).toBe(0);

  // 소진 뒤 낸 새 제출 — 대화가 있어도 「피드백 받기」 대신 소진 안내.
  await plantClaudeSession(GOOD_TURNS);
  await gradeAndSubmit(page, { attach: true });
  await expect(page.getByText(LIMIT_NOTICE)).toBeVisible();
  await expect(page.getByRole("button", { name: "피드백 받기" })).toHaveCount(0);
  await ctx.close();
});

test("수업 묶음의 시나리오 화면에는 피드백 칸(과정 피드백)과 「내 기록」이 없다", async ({ browser }) => {
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

  await page.goto(`/cohorts/${cohortId}`);
  await startAgent(page.request, await agentTokenFor(page, cohortId));
  await page.reload();
  await page.getByRole("link", { name: SCENARIO_TITLE }).click();
  await expect(page.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
  await prepareOnPage(page);
  await plantClaudeSession(GOOD_TURNS);
  const sub = await gradeAndSubmit(page, { attach: true });
  expect(sub.has_transcript).toBe(true); // 대화는 같이 올라가도 수업 묶음에는 피드백이 없다

  await expect(page.getByRole("heading", { name: "과정 피드백" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "피드백 받기" })).toHaveCount(0);
  await expect(page.getByText("피드백 확인 중…")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: "내 기록" })).toHaveCount(0);
  await ctx.close();
  await instructor.context().close();
});

test("내 기록: 두 번 제출 → 목록에 최고 점수·제출 수·시각(미제출은 「—」), 제출 이력 두 줄, 한 줄을 열면 검사별 결과와 피드백", async ({ browser }) => {
  const { ctx, page } = await newStudent(browser);
  await openPracticeScenario(page);
  await prepareOnPage(page);
  await plantClaudeSession(GOOD_TURNS);
  await gradeAndSubmit(page, { attach: true });
  await page.getByRole("button", { name: "피드백 받기" }).click();
  await expect(page.locator("table.sc-table", { hasText: "근거 인용" })).toBeVisible();
  await gradeAndSubmit(page, { attach: false });

  // 연습 목록: 제출한 시나리오는 제출 2·마지막 제출 시각·최고 1/1, 제출 없는 시나리오는 0·「—」·「—/1」.
  await page.getByRole("navigation", { name: "이동 경로" }).getByRole("link", { name: "연습" }).click();
  await page.waitForURL(/\/practice$/);
  const done = page.getByRole("row").filter({ has: page.getByRole("link", { name: SCENARIO_TITLE }) });
  await expect(done.getByRole("cell").nth(2)).toHaveText("2");
  await expect(done.getByRole("cell").nth(3)).not.toHaveText("—");
  await expect(done.getByRole("cell").nth(3)).toHaveText(/\d/);
  await expect(done.getByRole("cell").nth(4)).toHaveText("1/1");
  const untouched = page.getByRole("row").filter({ has: page.getByRole("link", { name: "e2e 미제출" }) });
  await expect(untouched.getByRole("cell").nth(2)).toHaveText("0");
  await expect(untouched.getByRole("cell").nth(3)).toHaveText("—");
  await expect(untouched.getByRole("cell").nth(4)).toHaveText("—/1");

  // 시나리오의 「내 기록」: 제출 이력 두 줄(최신이 위). 피드백을 받은 첫 제출을 열면 검사별 결과와 피드백.
  await done.getByRole("link", { name: SCENARIO_TITLE }).click();
  await expect(page.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "내 기록" }).click();
  const rows = page.getByRole("tabpanel").getByRole("listitem");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText("피드백 없음");
  await expect(rows.nth(1)).toContainText("피드백 있음");
  await expect(rows.nth(0)).toContainText("1/1");

  await rows.nth(1).getByRole("button").click();
  await expect(page.getByRole("heading", { name: /검사별 결과 · 1\/1/ })).toBeVisible();
  await expect(page.getByRole("tabpanel", { name: "내 기록" }).getByText("ready.txt 가 있다")).toBeVisible();
  const table = page.locator("table.sc-table", { hasText: "근거 인용" });
  await expect(table).toBeVisible();
  for (const label of LABELS) await expect(table.getByRole("row").filter({ hasText: label })).toBeVisible();
  await ctx.close();
});
