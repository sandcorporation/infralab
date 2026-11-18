// e2e 스택 손잡이 — scripts/ci.sh e2e 가 올린 compose 프로젝트를 시험에서 만진다(에이전트 토큰 넣어 올리기,
// workstation 의 /work 비우기, 강사 권한 주기). 에이전트·workstation 은 학생 PC 몫이라 서버가 대신 올려 주지 않는다.
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type APIRequestContext, type Page } from "@playwright/test";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.E2E_PROJECT ?? "infralab-e2e";
export const workstation = process.env.E2E_WORKSTATION ?? "infralab-e2e-workstation";

function compose(args: string[], env: Record<string, string> = {}): string {
  return execFileSync(
    "docker",
    ["compose", "-p", project, "-f", "docker/compose.dev.yaml", "-f", "docker/compose.e2e.yaml", "--profile", "agent", ...args],
    { cwd: repo, env: { ...process.env, ...env }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120_000 },
  );
}

/** 이 사용자의 토큰으로 에이전트를 (다시) 올리고 /api/status 가 답할 때까지 기다린다. */
export async function startAgent(request: APIRequestContext, token: string): Promise<void> {
  compose(["up", "-d", "--force-recreate", "--no-build", "agent"], { E2E_AGENT_TOKEN: token });
  await expect
    .poll(
      async () => {
        try {
          const res = await request.get("http://127.0.0.1:7777/api/status", {
            headers: { Authorization: `Bearer ${token}` },
            timeout: 2_000,
          });
          return res.status();
        } catch {
          return 0;
        }
      },
      { timeout: 30_000 },
    )
    .toBe(200);
}

/** 에이전트를 내린다 — 학생이 실습 환경을 켜지 않은 꼴. */
export function stopAgent(): void {
  compose(["rm", "-sf", "agent"]);
}

/** workstation 을 새 /work 로 다시 만든다 — 홈 볼륨(/root)은 그대로. 학생이 다른 기수 폴더에서 compose 를 올린 꼴. */
export function freshWorkDir(): void {
  compose(["rm", "-sf", "workstation"]);
  execFileSync("docker", ["volume", "rm", "-f", `${project}_e2e-work`], { stdio: "ignore" });
  compose(["up", "-d", "workstation"]);
}

/** workstation 안에서 명령을 돌려 출력을 준다. */
export function inWorkstation(...cmd: string[]): string {
  return execFileSync("docker", ["exec", workstation, ...cmd], { encoding: "utf8", timeout: 30_000 });
}

/** 기본 조직의 owner 로 — 강사 화면이 열린다. 사용자는 먼저 로그인으로 만들어져 있어야 한다. */
export function makeInstructor(uid: string): void {
  compose(["exec", "-T", "backend", "python", "manage.py", "set_instructor", `sandcorp:${uid}`]);
}

/** 개발용 로그인(DEBUG 전용 POST /api/auth/dev-login) — 브라우저 맥락의 쿠키로 세션을 연다. */
export async function devLogin(page: Page, uid: string, nickname: string): Promise<void> {
  const res = await page.request.post("/api/auth/dev-login", {
    data: { uid, nickname },
    headers: { Origin: baseOrigin() },
  });
  expect(res.status(), await res.text()).toBe(204);
}

export function baseOrigin(): string {
  return new URL(process.env.E2E_BASE_URL ?? "http://127.0.0.1:53050").origin;
}

/** 시험마다 겹치지 않는 uid. */
export function uniqueId(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

/** 내 기수 상세(GET /api/cohorts/<id>) — 에이전트 토큰을 여기서 받는다. */
export async function agentTokenFor(page: Page, cohortId: number): Promise<string> {
  const res = await page.request.get(`/api/cohorts/${cohortId}`);
  expect(res.status(), await res.text()).toBe(200);
  return ((await res.json()) as { agent_token: string }).agent_token;
}
