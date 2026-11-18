// AI 프록시(PR #97·#98): 응시 중 「AI 키 설정」을 workstation 에 붙여 넣으면 Claude Code 의 길(ANTHROPIC_BASE_URL)이
// 프록시를 가리키고, 그 길로 보낸 요청이 공급사 대답을 받는다. 담당자가 회수하면 같은 임시 토큰의 다음 요청은 401.
// e2e 스택의 프록시는 가짜 공급사 모드(INFRALAB_PROXY_FAKE_PROVIDER=1, docker/compose.e2e.yaml)라 진짜 키·외부 네트워크가 없다.
import { expect, test, type Page } from "@playwright/test";
import { AI_TOOL_MODELS, createExamCohort, headBadge, inviteRow, issueInvite, openScenario, startAttempt } from "./flows";
import { anthropicRequestFromWorkstation, examProvidersKnown, expireExam } from "./stack";
import { terminalScreen, typeInTerminal } from "./terminal";

/** backend 가 지원자에게 주는 프록시 주소(compose.e2e.yaml 의 INFRALAB_EXAM_PROXY_URL). workstation 이 같은 compose 망에 있다. */
const PROXY = "http://proxy:58090";
/** 가짜 공급사가 늘 주는 대답(proxy/fake.go FakeReply). */
const FAKE_REPLY = "infralab fake provider reply.";
const CLAUDE_MODEL = AI_TOOL_MODELS.find(([tool]) => tool === "Claude Code")![1];

const aiKeyHeading = (p: Page) => p.getByRole("heading", { name: "AI 키 설정" });
const aiTool = (p: Page, name: string) =>
  p.locator(".ai-key-setup .ai-key-tool").filter({ has: p.getByRole("heading", { name: new RegExp(`^${name}`) }) });
const clipboard = (p: Page) => p.evaluate(() => navigator.clipboard.readText());

test("「AI 키 설정」 복사 → workstation 의 ANTHROPIC_BASE_URL 이 프록시, 가짜 공급사 대답 — 담당자가 회수하면 다음 요청 401", async ({
  browser,
}) => {
  // backend 가 프록시에서 공급사 키 유무를 알아낸다(모름이 아니라 있음) — 그래서 회차 설정에서 두 도구를 고른다.
  expect(examProvidersKnown()).toEqual({ anthropic: true, openai: true });
  const cohort = await createExamCohort(browser, { aiTools: true });
  const label = "AI 키 지원자";
  const candidate = await startAttempt(browser, await issueInvite(cohort, label));
  const page = candidate.page;
  await expect(aiKeyHeading(page)).toBeVisible();

  // Codex: 설정 파일 안내와 「설정 파일 복사」 → 「복사했습니다」.
  const codex = aiTool(page, "Codex");
  await expect(codex.getByText("설정 파일 ~/.codex/config.toml 에 넣으세요.")).toBeVisible();
  await codex.getByRole("button", { name: "설정 파일 복사" }).click();
  await expect(codex.getByRole("button", { name: "복사했습니다" })).toBeVisible();
  expect(await clipboard(page)).toContain(`base_url = "${PROXY}/openai/v1"`);

  // Claude Code: 터미널 안내와 「환경변수 복사」 → 「복사했습니다」(앞 버튼은 원래 이름으로).
  const claude = aiTool(page, "Claude Code");
  await expect(claude.getByText("workstation 터미널에 붙여 넣으세요.")).toBeVisible();
  await claude.getByRole("button", { name: "환경변수 복사" }).click();
  await expect(claude.getByRole("button", { name: "복사했습니다" })).toBeVisible();
  await expect(codex.getByRole("button", { name: "설정 파일 복사" })).toBeVisible();
  const env = await clipboard(page);
  expect(env).toContain(`export ANTHROPIC_BASE_URL="${PROXY}/anthropic"`);
  const token = /ANTHROPIC_AUTH_TOKEN="([^"]+)"/.exec(env)?.[1];
  expect(token, env).toBeTruthy();

  // workstation 터미널에 그대로 붙여 넣는다(클립보드는 복사한 그대로) — 길이 프록시를 가리킨다.
  await openScenario(candidate);
  await page.locator(".terminal-host").click();
  await page.keyboard.press("Control+V");
  await page.keyboard.press("Enter");
  await typeInTerminal(page, 'echo "BASE=$ANTHROPIC_BASE_URL"');
  await page.keyboard.press("Enter");
  await expect(terminalScreen(page)).toContainText(`BASE=${PROXY}/anthropic`);

  // 그 길로 보낸 요청(Claude Code 가 부르는 /v1/messages)이 가짜 공급사 대답을 받고, 모델은 회차의 고정 모델로 바뀐다.
  await typeInTerminal(
    page,
    `wget -qO- --header "x-api-key: $ANTHROPIC_AUTH_TOKEN" --header "content-type: application/json" ` +
      `--post-data '{"model":"any","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' "$ANTHROPIC_BASE_URL/v1/messages"`,
  );
  await page.keyboard.press("Enter");
  await expect(terminalScreen(page)).toContainText(FAKE_REPLY);
  await expect(terminalScreen(page)).toContainText(`"model":"${CLAUDE_MODEL}"`);

  // 같은 workstation(같은 client_id)에서 같은 임시 토큰으로 — 회수 전에는 200.
  const before = anthropicRequestFromWorkstation(`${PROXY}/anthropic`, token!);
  expect(before).toContain("HTTP/1.1 200");
  expect(before).toContain(FAKE_REPLY);

  // 담당자 화면(응시 링크 표)에서 회수 → 같은 토큰의 다음 프록시 요청은 401, 공급사 대답 없음.
  const p = cohort.instructor;
  await p.reload();
  const row = inviteRow(p, label);
  await expect(row.getByText("응시 중")).toBeVisible();
  await row.getByRole("button", { name: "회수" }).click();
  await p.getByRole("dialog").getByRole("button", { name: "회수", exact: true }).click();
  await expect(row.getByText("회수됨")).toBeVisible();

  const after = anthropicRequestFromWorkstation(`${PROXY}/anthropic`, token!);
  expect(after).toMatch(/server returned error: HTTP\/1\.1 401/);
  expect(after).not.toContain(FAKE_REPLY);
  await candidate.ctx.close();
});

test("「AI 키 설정」 칸은 시작 전과 마감 뒤에는 없다", async ({ browser }) => {
  const cohort = await createExamCohort(browser, { aiTools: true });

  // 시작 전: 허용 도구는 안내되지만 키 설정 칸은 없다.
  const ctx = await browser.newContext();
  const waiting = await ctx.newPage();
  await waiting.goto(await issueInvite(cohort, "시작 전 지원자"));
  await expect(headBadge(waiting)).toHaveText("시작 전");
  await expect(waiting.locator(".sc-stat-value", { hasText: "Claude Code, Codex" })).toBeVisible();
  await expect(aiKeyHeading(waiting)).toHaveCount(0);
  await ctx.close();

  // 응시 중에는 있고, 마감 뒤(시계를 당긴다, 기다리지 않는다)에는 없다.
  const candidate = await startAttempt(browser, await issueInvite(cohort, "마감 지원자"));
  const page = candidate.page;
  await expect(aiKeyHeading(page)).toBeVisible();
  expireExam(candidate.cohortId);
  await page.reload();
  await expect(headBadge(page)).toHaveText("마감");
  await expect(page.getByText("시험이 마감되었습니다.")).toBeVisible();
  await expect(aiKeyHeading(page)).toHaveCount(0);
  await candidate.ctx.close();
});
