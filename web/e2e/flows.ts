// 화면 흐름 손잡이 — 강사가 시험 회차를 만들고 응시 링크를 내는 길, 응시자가 링크로 들어와 시작하는 길.
// 버튼·라벨은 화면 글자 그대로 찾는다(바뀌면 시험이 깨져 알려 준다).
import { expect, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { agentTokenFor, baseOrigin, devLogin, makeInstructor, startAgent, stopAgent, uniqueId } from "./stack";

export const SCENARIO_ID = "e2e-prepare";
export const SCENARIO_TITLE = "e2e 환경 준비";

export type ExamCohort = { instructor: Page; cohortId: number; name: string };

/** 강사로 로그인해 감독을 켠 시험 회차를 만들고 e2e 시나리오를 연다(설정 탭까지 화면으로). */
export async function createExamCohort(browser: Browser, opts: { hiddenChecks?: boolean } = {}): Promise<ExamCohort> {
  const ctx = await browser.newContext();
  const instructor = await ctx.newPage();
  const uid = uniqueId("instructor");
  await instructor.goto("/login");
  await devLogin(instructor, uid, "강사");
  makeInstructor(uid);

  const name = `e2e 시험 ${uid.slice(-4)}`;
  await instructor.goto("/instructor");
  await instructor.getByRole("button", { name: "새 기수" }).click();
  await instructor.getByRole("radio", { name: "시험" }).check();
  await instructor.getByRole("textbox", { name: "이름", exact: true }).fill(name);
  await instructor.getByRole("button", { name: "만들기" }).click();
  await instructor.waitForURL(/\/instructor\/cohorts\/\d+/);
  const cohortId = Number(/cohorts\/(\d+)/.exec(instructor.url())![1]);

  await instructor.getByRole("link", { name: /^시나리오/ }).click();
  await instructor.getByRole("checkbox", { name: new RegExp(SCENARIO_TITLE) }).check();
  await instructor.getByRole("button", { name: "저장" }).click();

  await instructor.getByRole("link", { name: "설정", exact: true }).last().click();
  await instructor.getByLabel("시간 제한(분)").fill("30");
  await instructor.getByRole("checkbox", { name: "감독" }).check();
  if (opts.hiddenChecks) await instructor.getByRole("checkbox", { name: "숨은 검사 사용" }).check();
  await instructor.getByRole("button", { name: "설정 저장" }).click();
  await expect(instructor.getByRole("status").filter({ hasText: "저장됨" })).toBeVisible();
  return { instructor, cohortId, name };
}

/** 응시 중 시나리오 화면에서 환경 준비를 확정하고 「준비됨」이 뜰 때까지. */
export async function prepareEnvironment(c: Candidate): Promise<void> {
  const p = c.page;
  await p.getByRole("button", { name: "환경 준비", exact: true }).click();
  await p.getByRole("button", { name: "환경 준비 확정" }).click();
  await expect(p.locator(".sc-badge--success", { hasText: "준비됨" })).toBeVisible({ timeout: 60_000 });
}

/** 상단 띠의 회차 이름으로 응시 화면(/exam/<토큰>)에 돌아간다 — 마감 뒤 숨은 검사는 이 화면이 돌린다. */
export async function backToExamPage(c: Candidate): Promise<void> {
  const p = c.page;
  await p.locator(".exam-bar").getByRole("link").click();
  await p.waitForURL(/\/exam\/[^/]+$/);
  await expect(headBadge(p)).toHaveText("응시 중");
}

/** 「제출하고 끝내기」 → 확인 대화상자의 「끝내기」. */
export async function finishAttempt(c: Candidate): Promise<void> {
  await c.page.getByRole("button", { name: "제출하고 끝내기" }).click();
  await c.page.getByRole("dialog").getByRole("button", { name: "끝내기", exact: true }).click();
}

/** 응시 링크 탭에서 링크를 하나 발급하고 그 주소(/exam/<토큰>)를 준다. */
export async function issueInvite(c: ExamCohort, label: string): Promise<string> {
  const p = c.instructor;
  await p.getByRole("link", { name: "응시 링크", exact: true }).click();
  await p.getByRole("button", { name: "응시 링크 발급" }).click();
  await p.getByLabel("지원자 표시 이름(메모)").fill(label);
  await p.getByRole("button", { name: "발급", exact: true }).click();
  const row = inviteRow(p, label);
  await expect(row.getByText("초대됨")).toBeVisible();
  const url = await row.getByRole("button", { name: "링크 복사" }).getAttribute("title");
  expect(url).toMatch(/\/exam\/[^/]+$/);
  return new URL(url!).pathname;
}

export const inviteRow = (p: Page, label: string) => p.getByRole("row").filter({ has: p.getByRole("link", { name: label }) });

export type Candidate = { ctx: BrowserContext; page: Page; cohortId: number; agentToken: string };

/**
 * 로그인하지 않은 새 브라우저로 응시 링크를 열고, 그 응시자 토큰으로 학생 PC 의 에이전트를 올린 뒤
 * 응시 전 점검을 통과시켜 「시작」한다. 붙여넣기를 쓰려고 클립보드 권한을 준다.
 */
export async function startAttempt(browser: Browser, examPath: string): Promise<Candidate> {
  const ctx = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  const entered = page.waitForResponse((r) => r.url().endsWith("/enter") && r.request().method() === "POST");
  await page.goto(examPath);
  const status = (await (await entered).json()) as { cohort_id: number };
  await expect(headBadge(page)).toHaveText("시작 전");
  const agentToken = await agentTokenFor(page, status.cohort_id);

  // 실습 환경(에이전트)이 꺼져 있으면 동의해도 「시작」이 막히고 설치 안내로 보낸다(PR #104).
  stopAgent();
  await page.getByRole("button", { name: "다시 점검" }).click();
  await page.getByLabel("위 안내를 읽었고 동의합니다.").check();
  const start = page.getByRole("button", { name: "시작", exact: true });
  await expect(start).toBeDisabled();
  await expect(page.getByRole("link", { name: "설치 안내" })).toBeVisible();

  await startAgent(page.request, agentToken);
  await page.getByRole("button", { name: "다시 점검" }).click();
  await expect(start).toBeEnabled();
  await start.click();
  await expect(headBadge(page)).toHaveText("응시 중");
  return { ctx, page, cohortId: status.cohort_id, agentToken };
}

/** 응시 중 화면에서 시나리오 페이지로 — 터미널이 연결될 때까지. */
export async function openScenario(c: Candidate): Promise<void> {
  const p = c.page;
  await p.getByRole("link", { name: "시나리오", exact: true }).click();
  await p.getByRole("link", { name: SCENARIO_TITLE }).click();
  await p.waitForURL(new RegExp(`/scenarios/${SCENARIO_ID}$`));
  await expect(p.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
}

/** 응시 화면 머리 배지 — 「시작 전」「응시 중」「마감」. */
export const headBadge = (p: Page) => p.getByRole("heading").locator(".sc-badge");

/** 새 브라우저로 개발용 로그인한 학생 — 어느 수업 묶음에도 들지 않았다. */
export async function newStudent(browser: Browser, label = "연습생"): Promise<{ ctx: BrowserContext; page: Page; uid: string }> {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const uid = uniqueId("student");
  await page.goto("/login");
  await devLogin(page, uid, label);
  return { ctx, page, uid };
}

/** 묶음 없는 계정의 `/` 가 연습 화면으로 가고, 「연습 시작」으로 참여해 시나리오 목록이 뜰 때까지. */
export async function startPractice(page: Page): Promise<void> {
  await page.goto("/");
  await page.waitForURL(/\/practice$/);
  await page.getByRole("button", { name: "연습 시작" }).click();
  await expect(practiceRow(page)).toBeVisible();
}

/** 연습 화면의 e2e 시나리오 행. */
export const practiceRow = (p: Page) => p.getByRole("row").filter({ has: p.getByRole("link", { name: SCENARIO_TITLE }) });

/** 이미 강사 권한이 있는 사람이 수업 묶음을 API 로 만들고, 이 학생이 가입 링크로 들어가 수업 묶음 계정이 되게 한다. */
export async function joinClassCohort(instructor: Page, student: Page): Promise<string> {
  const name = `e2e 수업 ${uniqueId("c").slice(-4)}`;
  const res = await instructor.request.post("/api/instructor/cohorts", {
    data: { name, kind: "class" },
    headers: { Origin: baseOrigin() },
  });
  expect(res.status(), await res.text()).toBe(201);
  const { join_token } = (await res.json()) as { join_token: string };
  await student.goto(`/join/${join_token}`);
  await expect(student.getByText(`「${name}」에 가입했습니다.`)).toBeVisible();
  return name;
}

/** 강사 권한을 가진 새 브라우저 맥락. */
export async function newInstructor(browser: Browser): Promise<Page> {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const uid = uniqueId("instructor");
  await page.goto("/login");
  await devLogin(page, uid, "강사");
  makeInstructor(uid);
  return page;
}
