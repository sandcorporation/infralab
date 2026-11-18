// 보고서 루브릭 채점(PR #102)과 끝난 회차 대시보드(PR #103). 응시 중 AI 요청은 e2e 스택의 가짜 공급사 프록시를 거쳐 기록되고,
// 채점은 공급사 키 없는 결정적 가짜 채점기(backend/exams/grading.py FakeGrader)가 한다 — 진짜 AI 없이.
import { expect, test, type Page } from "@playwright/test";
import { createExamCohort, finishAttempt, headBadge, inviteRow, issueInvite, startAttempt, type ExamCohort } from "./flows";
import { anthropicRequestFromWorkstation } from "./stack";

const PROXY = "http://proxy:58090";
/** 네 항목 단서(먼저·aws·확인·rm -rf)가 든 요청 — 가짜 채점기가 요청 안의 이 문장을 근거로 인용한다. */
const PROMPT = "먼저 aws s3 ls 로 버킷 이름을 확인해. rm -rf 는 쓰지 마. 그다음 결과를 검증해.";
const GUARD_QUOTE = "rm -rf 는 쓰지 마.";
const ITEMS = ["문제 나누기", "지시 명확성", "결과 검증", "위험 명령 막기"];

/** 응시자가 「환경변수 복사」로 받은 임시 토큰으로 프록시에 AI 요청을 보내고 제출하고 끝낸다. 지원자의 응시 링크 행 이름을 준다. */
async function candidateUsesAiAndFinishes(browser: Parameters<typeof startAttempt>[0], cohort: ExamCohort, label: string): Promise<void> {
  const candidate = await startAttempt(browser, await issueInvite(cohort, label));
  const page = candidate.page;
  const claude = page.locator(".ai-key-setup .ai-key-tool").filter({ has: page.getByRole("heading", { name: /^Claude Code/ }) });
  await claude.getByRole("button", { name: "환경변수 복사" }).click();
  await expect(claude.getByRole("button", { name: "복사했습니다" })).toBeVisible();
  const env = await page.evaluate(() => navigator.clipboard.readText());
  const token = /ANTHROPIC_AUTH_TOKEN="([^"]+)"/.exec(env)?.[1];
  expect(token, env).toBeTruthy();
  const res = anthropicRequestFromWorkstation(`${PROXY}/anthropic`, token!, PROMPT);
  expect(res).toContain("HTTP/1.1 200");

  await finishAttempt(candidate);
  await expect(headBadge(page)).toHaveText("마감");
  await candidate.ctx.close();
}

/** 응시 링크 표에서 그 지원자의 보고서를 열고 「루브릭」 탭까지. */
async function openReportRubric(p: Page, label: string): Promise<void> {
  await p.reload();
  const row = inviteRow(p, label);
  await expect(row.getByText("끝남")).toBeVisible();
  await row.getByRole("link", { name: label }).click();
  await p.waitForURL(/\/exam-invites\/\d+\/report$/);
  await p.getByRole("tab", { name: /^루브릭/ }).click();
}

const rubricRow = (p: Page, item: string) => p.getByRole("row").filter({ has: p.getByRole("cell", { name: item, exact: true }) });

test("보고서 「루브릭 채점」: 네 항목 점수와 근거 — 한 항목을 고치면 수정 이력, 「다시 채점」 뒤 이력은 남고 점수는 채점기 값으로", async ({
  browser,
}) => {
  const cohort = await createExamCohort(browser, { aiTools: true });
  const label = "채점 지원자";
  await candidateUsesAiAndFinishes(browser, cohort, label);
  const p = cohort.instructor;
  await openReportRubric(p, label);

  // 채점 전.
  await expect(p.getByText("아직 채점하지 않았습니다.")).toBeVisible();
  await p.getByRole("button", { name: "루브릭 채점" }).click();
  await expect(p.getByRole("button", { name: "다시 채점" })).toBeVisible();
  await expect(p.getByText(/^가짜 채점기/)).toBeVisible();

  // 네 항목 모두 점수와 근거(프록시가 기록한 요청 안의 글)가 보인다.
  for (const item of ITEMS) {
    const row = rubricRow(p, item);
    await expect(row.getByRole("cell").nth(1)).toHaveText(/^\d\/5\s*$/);
    await expect(row.locator("blockquote.evidence").first()).toBeVisible();
  }
  await expect(rubricRow(p, "위험 명령 막기").locator("blockquote.evidence").first()).toContainText(GUARD_QUOTE);

  // 한 항목(결과 검증)을 고친다 — 채점기 값과 다른 점수로.
  const verification = rubricRow(p, "결과 검증");
  const llm = Number((await verification.getByRole("cell").nth(2).innerText()).split("/")[0]);
  const edited = llm === 5 ? 0 : 5;
  await verification.getByRole("button", { name: "고치기" }).click();
  const dialog = p.getByRole("dialog");
  await dialog.getByLabel("점수 (0–5)").fill(String(edited));
  await dialog.getByLabel("사유").fill("직접 보니 다르다");
  await dialog.getByRole("button", { name: "저장" }).click();
  await expect(verification.getByRole("cell").nth(1)).toContainText(`${edited}/5`);
  await expect(verification.getByText("수정됨")).toBeVisible();
  await expect(verification.getByRole("cell").nth(2)).toHaveText(new RegExp(`^${llm}/5\\s*$`));

  const line = `결과 검증 ${llm} → ${edited}: 직접 보니 다르다`;
  await p.getByRole("tab", { name: /^이력/ }).click();
  await expect(p.getByRole("tabpanel").getByRole("listitem")).toHaveCount(1);
  await expect(p.getByRole("tabpanel").getByRole("listitem")).toContainText(line);

  // 다시 채점 — 이력은 남고 점수는 채점기 값으로 돌아간다.
  await p.getByRole("button", { name: "다시 채점" }).click();
  await expect(p.getByRole("tabpanel").getByRole("listitem")).toContainText(line);
  await expect(p.getByRole("tabpanel").getByRole("listitem")).toHaveCount(1);
  await p.getByRole("tab", { name: /^루브릭/ }).click();
  await expect(rubricRow(p, "결과 검증").getByRole("cell").nth(1)).toHaveText(new RegExp(`^${llm}/5\\s*$`));
  await expect(rubricRow(p, "결과 검증").getByText("수정됨")).toHaveCount(0);
});

test("끝난 회차의 대시보드: 회차 행(초대·시작·완료)과 점수 분포 막대", async ({ browser }) => {
  const cohort = await createExamCohort(browser, { aiTools: true });
  await candidateUsesAiAndFinishes(browser, cohort, "대시보드 지원자");
  const p = cohort.instructor;

  await p.goto("/instructor/exams");
  const row = p.getByRole("row").filter({ has: p.getByRole("link", { name: cohort.name, exact: true }) });
  await expect(row).toBeVisible();
  // 초대 1·시작 1·완료 1.
  await expect(row.getByRole("cell").nth(1)).toHaveText("1");
  await expect(row.getByRole("cell").nth(2)).toHaveText("1");
  await expect(row.getByRole("cell").nth(3)).toHaveText("1");
  // 제출 없이 끝냈으니 검사 0/1 → 0점 구간에 한 명.
  const dist = row.getByRole("img", { name: /^점수 분포/ });
  await expect(dist).toHaveAttribute("aria-label", "점수 분포 0–19점 1명, 20–39점 0명, 40–59점 0명, 60–79점 0명, 80–100점 0명");
  await expect(dist.locator(".bar")).toHaveCount(5);
});
