// e2e 스택 손잡이 — scripts/ci.sh e2e 가 올린 compose 프로젝트를 시험에서 만진다(에이전트 토큰 넣어 올리기,
// workstation 의 /work 비우기, 강사 권한 주기). 에이전트·workstation 은 학생 PC 몫이라 서버가 대신 올려 주지 않는다.
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type APIRequestContext, type Page } from "@playwright/test";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.E2E_PROJECT ?? "infralab-e2e";
export const workstation = process.env.E2E_WORKSTATION ?? "infralab-e2e-workstation";

/**
 * 떠 있는 compose 서비스 안에서 명령을 돈다(`docker compose exec -T`). 시험은 컨테이너를 만들거나 지우지 않는다 —
 * 그래서 `up`·`rm` 은 이 손잡이로 부를 수 없다. 시험 중 컨테이너를 만들면 호스트에 veth 가 생기고 Chromium 이 그때
 * 진행 중인 요청을 net::ERR_NETWORK_CHANGED 로 끊는다(#227·#232). 컨테이너는 scripts/ci.sh e2e 가 스택과 함께 한 번 만든다.
 */
function composeExec(args: string[]): string {
  return execFileSync(
    "docker",
    ["compose", "-p", project, "-f", "docker/compose.dev.yaml", "-f", "docker/compose.e2e.yaml", "--profile", "agent", "exec", "-T", ...args],
    { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120_000 },
  );
}

/**
 * 이 사용자의 토큰으로 에이전트를 (다시) 띄우고 /api/status 가 답할 때까지 기다린다.
 * 컨테이너는 다시 만들지 않고 그 안의 프로세스만 바꾼다(`docker/agent-e2e/agentctl`) — 재생성은 호스트에 veth 를 만들어
 * Chromium 이 진행 중인 요청을 net::ERR_NETWORK_CHANGED 로 끊는다(#227).
 */
export async function startAgent(request: APIRequestContext, token: string): Promise<void> {
  composeExec(["-e", `AGENT_TOKEN=${token}`, "agent", "agentctl", "start"]);
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

/** 에이전트를 내린다 — 학생이 실습 환경을 켜지 않은 꼴. 컨테이너는 남긴다(위 까닭). */
export function stopAgent(): void {
  composeExec(["agent", "agentctl", "stop"]);
}

/**
 * workstation 의 /work 를 비운다 — 홈 볼륨(/root)은 그대로. 학생이 다른 기수 폴더에서 compose 를 올린 꼴.
 * 컨테이너는 다시 만들지 않는다(#232, 위 composeExec 의 까닭). 다시 만들 때처럼 그 안에서 돌던 것(터미널 셸·검사)은
 * 끝낸다 — `kill -9 -1` 은 컨테이너 PID 이름공간 안에서 PID 1(sleep)과 이 셸만 빼고 모두에게 간다.
 */
export function freshWorkDir(): void {
  composeExec(["workstation", "sh", "-c", "kill -9 -1 2>/dev/null; find /work -mindepth 1 -delete"]);
}

/** workstation 안에서 명령을 돌려 출력을 준다. */
export function inWorkstation(...cmd: string[]): string {
  return execFileSync("docker", ["exec", workstation, ...cmd], { encoding: "utf8", timeout: 30_000 });
}

/**
 * workstation 에서 Claude Code 처럼 AI 프록시의 Anthropic 길(`<ANTHROPIC_BASE_URL>/v1/messages`)로 요청 하나를 보낸다.
 * busybox wget 의 서버 응답 머리(-S)·본문·오류 줄을 그대로 준다 — 4xx 면 `server returned error: HTTP/1.1 401 …`.
 */
export function anthropicRequestFromWorkstation(baseUrl: string, token: string, content = "hello"): string {
  const body = JSON.stringify({ model: "e2e", max_tokens: 16, messages: [{ role: "user", content }] });
  const script = 'wget -S -O- --header "x-api-key: $1" --header "content-type: application/json" --post-data "$2" "$3/v1/messages" 2>&1; true';
  return execFileSync("docker", ["exec", workstation, "sh", "-c", script, "sh", token, body, baseUrl], {
    encoding: "utf8",
    timeout: 30_000,
  });
}

/** workstation 안의 파일을 만든다(상위 폴더 포함) — 학생이 AI 도구로 남긴 세션 기록을 심는 데 쓴다. */
export function writeInWorkstation(path: string, content: string): void {
  const dir = path.slice(0, path.lastIndexOf("/"));
  execFileSync("docker", ["exec", "-i", workstation, "sh", "-c", `mkdir -p '${dir}' && cat > '${path}'`], {
    input: content,
    encoding: "utf8",
    timeout: 30_000,
  });
}

/** 기본 조직의 owner 로 — 강사 화면이 열린다. 사용자는 먼저 로그인으로 만들어져 있어야 한다. */
export function makeInstructor(uid: string): void {
  composeExec(["backend", "python", "manage.py", "set_instructor", `sandcorp:${uid}`]);
}

/** 조직을 만들고 첫 담당자(owner)를 넣는다(`create_org`). 사용자는 먼저 로그인으로 만들어져 있어야 한다. */
export function createOrg(name: string, ownerUid: string): void {
  composeExec(["backend", "python", "manage.py", "create_org", name, "--owner", `sandcorp:${ownerUid}`]);
}

/** 조직에 담당자를 넣는다(`add_org_member`, 기본 owner). 사용자는 먼저 로그인으로 만들어져 있어야 한다. */
export function addOrgMember(org: string, uid: string, role: "owner" | "staff" = "owner"): void {
  composeExec(["backend", "python", "manage.py", "add_org_member", org, `sandcorp:${uid}`, "--role", role]);
}

/** 시계를 당긴다(e2e 전용 관리 명령, #194) — 그 회차의 응시 중인 응시가 마감이 지난 꼴이 된다. 1분을 기다리지 않는다. */
export function expireExam(cohortId: number): void {
  composeExec(["backend", "python", "manage.py", "e2e_expire_exam", String(cohortId)]);
}

/** backend 가 AI 프록시에서 알아낸 공급사 키 유무(키 값이 아니라 있다·없다). 모르면(프록시를 못 부름) null. */
export function examProvidersKnown(): { anthropic: boolean; openai: boolean } | null {
  const out = composeExec([
    "backend",
    "python",
    "manage.py",
    "shell",
    "-c",
    "import json; from exams import providers; providers.clear_cache(); print(json.dumps(providers.configured()))",
  ]);
  return JSON.parse(out.trim().split("\n").pop()!) as { anthropic: boolean; openai: boolean } | null;
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
