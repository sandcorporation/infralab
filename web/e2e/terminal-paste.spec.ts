// #126(PR #129) 회귀: 시나리오 터미널의 Ctrl+V 붙여넣기.
// 옛 버그 — xterm 이 Ctrl+V 를 ^V(\x16) 로 bash 에 보내고 keydown 을 막아 붙여넣기가 일어나지 않았고, 감독 신호도 없었다.
import { expect, test } from "@playwright/test";
import { createExamCohort, inviteRow, issueInvite, openScenario, startAttempt } from "./flows";
import { pasteIntoTerminal, recordTerminalInput, terminalScreen } from "./terminal";

test("터미널 Ctrl+V 는 bash 에 붙여넣은 글자만 보내고(^V 없음) 감독 신호 「붙여넣기」 1건을 남긴다", async ({ browser }) => {
  const cohort = await createExamCohort(browser);
  const label = "붙여넣기 지원자";
  const candidate = await startAttempt(browser, await issueInvite(cohort, label));
  const page = candidate.page;
  const sent = recordTerminalInput(page);
  await openScenario(candidate);

  // 붙여넣은 명령이 bash 에서 실제로 돈다 — 출력 P42Q 는 명령 글자에 없는 문자열이다.
  await pasteIntoTerminal(page, "printf 'P%sQ\\n' 42");
  await page.keyboard.press("Enter");
  await expect(terminalScreen(page)).toContainText("P42Q");

  const input = sent.join("");
  expect(input).not.toContain("\x16");
  expect(input.split("printf 'P%sQ\\n' 42").length - 1, "붙여넣은 글자는 한 번만 간다").toBe(1);

  // 강사 화면: 감독 신호 「붙여넣기」 정확히 1건, 세부는 붙여넣은 글자.
  const p = cohort.instructor;
  await p.reload();
  const row = inviteRow(p, label);
  await expect(row.getByText("응시 중")).toBeVisible();
  await row.getByRole("button", { name: /건$/ }).click();
  const events = p.locator("ol.events li");
  await expect(events.filter({ hasText: "붙여넣기" })).toHaveCount(1);
  await expect(events.filter({ hasText: "붙여넣기" })).toContainText("printf 'P%sQ\\n' 42");
  await candidate.ctx.close();
});
