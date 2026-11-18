// 조직·기수 관리(PR #57·#58): 담당자의 기수 → 격자 → 제출 Drawer, 조직 고르기, 초대 링크 수락, staff 의 조직 탭, 마지막 owner.
// 사용자·조직은 `create_org`·`add_org_member` 손잡이(stack.ts)로 만들고, 화면 조작은 화면 글자 그대로 찾는다.
import { expect, test, type Browser, type Page } from "@playwright/test";
import { SCENARIO_ID, apiSubmit } from "./flows";
import { addOrgMember, baseOrigin, createOrg, devLogin, makeInstructor, uniqueId } from "./stack";

/** 새 브라우저 맥락으로 로그인한 사용자(클립보드 권한 포함). */
async function login(browser: Browser, label: string): Promise<{ page: Page; uid: string }> {
  const ctx = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  const uid = uniqueId("org");
  await page.goto("/login");
  await devLogin(page, uid, label);
  return { page, uid };
}

const orgName = () => `e2e 조직 ${uniqueId("o").slice(-5)}`;

test("담당자: 기수 목록 → 기수 관리 → 격자 → 제출이 있는 칸 → 제출 Drawer 에 제출 내용", async ({ browser }) => {
  const { page: boss, uid } = await login(browser, "격자강사");
  makeInstructor(uid);
  const name = `e2e 격자 ${uniqueId("g").slice(-4)}`;
  const created = await boss.request.post("/api/instructor/cohorts", { data: { name, kind: "class" }, headers: { Origin: baseOrigin() } });
  expect(created.status(), await created.text()).toBe(201);
  const cohort = (await created.json()) as { id: number; join_token: string };
  const open = await boss.request.put(`/api/instructor/cohorts/${cohort.id}/scenarios`, {
    data: { scenario_ids: [SCENARIO_ID] },
    headers: { Origin: baseOrigin() },
  });
  expect(open.status(), await open.text()).toBe(200);

  // 학생이 가입해 제출 하나를 낸다(에이전트 없이 API).
  const { page: student } = await login(browser, "격자학생");
  await student.goto(`/join/${cohort.join_token}`);
  await expect(student.getByText(`「${name}」에 가입했습니다.`)).toBeVisible();
  await apiSubmit(student, cohort.id, SCENARIO_ID, "ready-file");

  // 담당자 화면: 기수 목록 → 기수 관리 → 진행(격자) → 칸 → Drawer.
  await boss.goto("/instructor");
  await boss.getByRole("link", { name, exact: true }).click();
  await boss.waitForURL(new RegExp(`/instructor/cohorts/${cohort.id}$`));
  await boss.getByRole("link", { name: "진행", exact: true }).click();
  await boss.waitForURL(/\/grid$/);
  await expect(boss.getByRole("row").filter({ hasText: "격자학생" })).toBeVisible();
  await boss.getByRole("button", { name: /1\/1/ }).click();

  const drawer = boss.getByRole("dialog");
  await expect(drawer.getByRole("heading", { name: /격자학생/ })).toBeVisible();
  // 서버는 검사 이름을 시나리오 정의(`ready.txt 가 있다`)에서 붙인다 — 올린 이름이 아니다.
  await expect(drawer.getByText("ready.txt 가 있다", { exact: true })).toBeVisible();
  await expect(drawer.getByText("ready", { exact: true })).toBeVisible();
  await expect(drawer.getByRole("heading", { name: /1\/1/ })).toBeVisible();
});

test("조직 둘인 담당자가 다른 조직을 고르고 새로 고침해도 그 조직이 남는다", async ({ browser }) => {
  const { page, uid } = await login(browser, "두 조직 담당");
  makeInstructor(uid); // 기본 조직
  const second = orgName();
  createOrg(second, uid);

  await page.goto("/instructor");
  const select = page.getByLabel("조직", { exact: true });
  await expect(select.locator("option")).toHaveCount(2);
  // 지금 고른 것이 아닌 쪽을 고른다.
  const current = (await select.locator("option:checked").innerText()).trim();
  const options = (await select.locator("option").allInnerTexts()).map((t) => t.trim());
  const other = options.find((o) => o !== current)!;
  await select.selectOption({ label: other });
  await expect(select.locator("option:checked")).toHaveText(other);

  await page.reload();
  await expect(page.getByLabel("조직", { exact: true }).locator("option:checked")).toHaveText(other);
  // 조직 탭도 같은 선택을 따른다.
  await page.getByRole("link", { name: "조직", exact: true }).click();
  await expect(page.getByLabel("조직", { exact: true }).locator("option:checked")).toHaveText(other);
});

test("owner 가 조직 탭에서 초대 링크를 발급·복사 → 로그아웃 브라우저로 링크 → 로그인 → 수락 → 기수 목록", async ({ browser }) => {
  const { page: owner, uid } = await login(browser, "조직 owner");
  const org = orgName();
  createOrg(org, uid);

  await owner.goto("/instructor/org");
  await owner.getByRole("button", { name: "담당자 초대" }).click();
  await owner.getByRole("radio", { name: "staff", exact: true }).click();
  await owner.getByRole("button", { name: "발급", exact: true }).click();
  const copy = owner.getByRole("button", { name: "링크 복사" });
  await expect(copy).toBeVisible();
  await copy.click();
  await expect(owner.getByRole("button", { name: "복사됨" })).toBeVisible();
  const link = await owner.evaluate(() => navigator.clipboard.readText());
  expect(new URL(link).pathname).toMatch(/^\/org-invite\/[^/]+$/);

  // 로그인하지 않은 새 브라우저: 조직 이름을 보고 로그인 → 자동 수락 → 기수 목록.
  const ctx = await browser.newContext();
  const guest = await ctx.newPage();
  await guest.goto(new URL(link).pathname);
  await expect(guest.getByText(org, { exact: true })).toBeVisible();
  await guest.getByRole("link", { name: "로그인하고 수락하기" }).click();
  await guest.getByLabel("아이디").fill(uniqueId("invitee"));
  await guest.getByRole("button", { name: "로그인", exact: true }).click();
  await guest.waitForURL(/\/instructor$/);
  await expect(guest.getByRole("heading", { name: "기수", exact: true })).toBeVisible();
  await expect(guest.getByText(org, { exact: true })).toBeVisible();
  await ctx.close();
});

test("staff 의 조직 탭은 안내 문구만 보이고 발급·관리 버튼이 없다", async ({ browser }) => {
  const { uid: ownerUid } = await login(browser, "조직 owner");
  const org = orgName();
  createOrg(org, ownerUid);
  const { page: staff, uid } = await login(browser, "조직 staff");
  addOrgMember(org, uid, "staff");

  await staff.goto("/instructor");
  await staff.getByRole("link", { name: "조직", exact: true }).click();
  await expect(staff.getByText("owner 만 담당자를 관리할 수 있습니다. 내 역할: staff")).toBeVisible();
  await expect(staff.getByRole("button", { name: "담당자 초대" })).toHaveCount(0);
  await expect(staff.getByRole("button", { name: /^(owner|staff) 로$/ })).toHaveCount(0);
  await expect(staff.getByRole("button", { name: "내보내기" })).toHaveCount(0);
  await expect(staff.getByRole("button", { name: "링크 복사" })).toHaveCount(0);
});

test("마지막 owner 의 「staff 로」·「내보내기」는 오류 문구를 보이고 역할이 그대로다", async ({ browser }) => {
  const { page, uid } = await login(browser, "마지막 owner");
  createOrg(orgName(), uid);

  await page.goto("/instructor/org");
  const row = page.getByRole("row").filter({ hasText: "마지막 owner" });
  await expect(row.locator(".sc-badge")).toHaveText("owner");

  await row.getByRole("button", { name: "staff 로" }).click();
  await expect(page.getByText(/역할 바꾸기 실패: 마지막 owner 는 staff 로 내릴 수 없습니다/)).toBeVisible();
  await expect(row.locator(".sc-badge")).toHaveText("owner");

  await row.getByRole("button", { name: "내보내기" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "내보내기", exact: true }).click();
  await expect(page.getByText(/내보내기 실패: 마지막 owner 는 내보낼 수 없습니다/)).toBeVisible();
  await expect(row.locator(".sc-badge")).toHaveText("owner");

  await page.reload();
  await expect(page.getByRole("row").filter({ hasText: "마지막 owner" }).locator(".sc-badge")).toHaveText("owner");
});
