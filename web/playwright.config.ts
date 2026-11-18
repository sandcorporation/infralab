import { defineConfig, devices } from "@playwright/test";

// 브라우저 e2e — scripts/ci.sh e2e 가 개발 스택을 띄우고 E2E_BASE_URL 을 준다.
// 학생 에이전트는 127.0.0.1:7777 하나뿐이라 시험을 차례로 돈다(workers 1). 재시도 없음 — 불안정은 숨기지 않는다.
export default defineConfig({
  testDir: "e2e",
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  reporter: process.env.CI ? [["list"], ["github"]] : "list",
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:53050",
    trace: "retain-on-failure",
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
