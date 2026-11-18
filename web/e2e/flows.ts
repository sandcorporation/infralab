// 화면 흐름 손잡이 — 강사가 시험 회차를 만들고 응시 링크를 내는 길, 응시자가 링크로 들어와 시작하는 길.
// 버튼·라벨은 화면 글자 그대로 찾는다(바뀌면 시험이 깨져 알려 준다).
import { expect, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { agentTokenFor, baseOrigin, devLogin, makeInstructor, startAgent, stopAgent, uniqueId, writeInWorkstation } from "./stack";

export const SCENARIO_ID = "e2e-prepare";
export const SCENARIO_TITLE = "e2e 환경 준비";

/** AI 도구를 켠 회차의 도구(화면 이름)와 고정 모델. */
export const AI_TOOL_MODELS: [string, string][] = [
  ["Claude Code", "e2e-claude-model"],
  ["Codex", "e2e-codex-model"],
];

export type ExamCohort = { instructor: Page; cohortId: number; name: string };

/** 강사로 로그인해 감독을 켠 시험 회차를 만들고 e2e 시나리오를 연다(설정 탭까지 화면으로). */
export async function createExamCohort(
  browser: Browser,
  opts: { hiddenChecks?: boolean; aiTools?: boolean } = {},
): Promise<ExamCohort> {
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
  if (opts.aiTools) {
    // e2e 스택의 AI 프록시는 가짜 공급사 모드라 두 공급사 키가 다 있는 셈이다(#195) — 둘 다 고를 수 있다.
    for (const [tool, model] of AI_TOOL_MODELS) {
      await instructor.getByRole("checkbox", { name: tool, exact: true }).check();
      await instructor.getByRole("textbox", { name: `${tool} 모델` }).fill(model);
    }
  }
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

// ---- 연습 피드백·내 기록(#143·#144) ----

/** 학생이 AI 도구로 남긴 Claude Code 세션 기록을 workstation 홈에 심는다. 환경 준비 뒤(표시 시각 이후)에 심어야 읽힌다. */
export async function plantClaudeSession(turns: { role: "user" | "assistant"; text: string }[]): Promise<void> {
  // 에이전트는 준비 표시보다 「나중에 바뀐」 파일만 읽는다(find -newer, 초 단위) — 표시와 같은 초에 심으면 빠진다.
  await new Promise((r) => setTimeout(r, 1_200));
  const base = Date.now();
  const lines = turns.map((t, i) => {
    const timestamp = new Date(base + i).toISOString();
    const content = t.role === "user" ? t.text : [{ type: "text", text: t.text }];
    return JSON.stringify({ type: t.role, timestamp, message: { role: t.role, content } });
  });
  writeInWorkstation(`/root/.claude/projects/e2e/${uniqueId("session")}.jsonl`, lines.join("\n") + "\n");
}

/** 가짜 채점기가 네 항목 모두 점수를 주는 대화(요청마다 단서가 든 문장). */
export const GOOD_TURNS: { role: "user" | "assistant"; text: string }[] = [
  { role: "user", text: "먼저 `aws s3 ls` 로 버킷 이름을 확인해 줘. rm -rf 는 쓰지 마." },
  { role: "assistant", text: "그다음 결과를 검증하겠습니다." },
];

/** 연습 시나리오 화면에서 에이전트를 올리고(연습 묶음 토큰) 터미널이 연결될 때까지. */
export async function openPracticeScenario(page: Page, title = SCENARIO_TITLE): Promise<number> {
  await startPractice(page);
  const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: title }) });
  const cohortId = Number(/cohorts\/(\d+)/.exec((await row.getByRole("link").getAttribute("href"))!)![1]);
  await startAgent(page.request, await agentTokenFor(page, cohortId));
  await page.reload();
  await page.getByRole("link", { name: title }).click();
  await page.waitForURL(/\/cohorts\/\d+\/scenarios\/[^/]+$/);
  await expect(page.locator(".terminal").getByText("연결됨", { exact: true })).toBeVisible();
  return cohortId;
}

/** 환경 준비를 확정하고 「준비됨」이 뜰 때까지(응시 아닌 화면용). */
export async function prepareOnPage(page: Page): Promise<void> {
  await page.getByRole("button", { name: "환경 준비", exact: true }).click();
  await page.getByRole("button", { name: "환경 준비 확정" }).click();
  await expect(page.locator(".sc-badge--success", { hasText: "준비됨" })).toBeVisible({ timeout: 60_000 });
}

/** 「AI 대화 함께 제출」을 켜거나 끄고 「채점」 — 서버에 제출이 올라올 때까지. 올라온 제출을 준다. */
export async function gradeAndSubmit(page: Page, opts: { attach: boolean }): Promise<{ id: number; has_transcript: boolean }> {
  await page.getByRole("tab", { name: /^검사/ }).click();
  const box = page.getByRole("checkbox", { name: "AI 대화 함께 제출" });
  if (opts.attach) await box.check();
  else await box.uncheck();
  const posted = page.waitForResponse((r) => /\/submissions$/.test(r.url()) && r.request().method() === "POST", { timeout: 60_000 });
  await page.getByRole("button", { name: "채점", exact: true }).click();
  const res = await posted;
  expect(res.status(), await res.text()).toBe(201);
  const sub = (await res.json()) as { id: number; has_transcript: boolean };
  await expect(page.getByText(/^제출됨/)).toBeVisible();
  return sub;
}

/** 에이전트를 거치지 않고 API 로 제출 하나(대화 포함)를 올린다 — 하루 한도를 채우는 데 쓴다. */
export async function apiSubmit(page: Page, cohortId: number, scenarioId: string, checkId: string): Promise<number> {
  const at = new Date().toISOString();
  const res = await page.request.post(`/api/cohorts/${cohortId}/scenarios/${scenarioId}/submissions`, {
    data: {
      agent_version: "e2e",
      results: [{ id: checkId, name: checkId, hint: "", pass: true, output: "ready", truncated: false, exit_code: 0, error: "" }],
      ai_transcript: [{ tool: "claude", since: at, truncated: false, entries: GOOD_TURNS.map((t) => ({ ...t, at })) }],
    },
    headers: { Origin: baseOrigin() },
  });
  expect(res.status(), await res.text()).toBe(201);
  return ((await res.json()) as { id: number }).id;
}

/** 피드백을 API 로 받는다(횟수를 하나 쓴다). */
export async function apiFeedback(page: Page, submissionId: number): Promise<void> {
  const res = await page.request.post(`/api/practice/submissions/${submissionId}/feedback`, { headers: { Origin: baseOrigin() } });
  expect(res.status(), await res.text()).toBe(200);
}

/** 오늘 남은 피드백 횟수. */
export async function feedbackRemaining(page: Page): Promise<number> {
  const res = await page.request.get("/api/practice/feedback-quota");
  expect(res.status(), await res.text()).toBe(200);
  return ((await res.json()) as { remaining: number }).remaining;
}
