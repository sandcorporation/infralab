// 학생 PC 의 로컬 에이전트(127.0.0.1:7777) 클라이언트. 서버와는 별개의 오리진이라 fetch 가 CORS 를 탄다 —
// 에이전트는 대시보드 오리진에서 온 요청에만 헤더를 준다.
import type { Preflight } from "./exam";

export type AgentStatus = {
  version: string;
  docker_server: string;
  docker_error?: string;
  workstation: string; // running | exited | missing …
  floci: string;
  kind_nodes: string[];
};

/** 에이전트가 안 떠 있거나(연결 거부), Chrome 이 로컬 네트워크 접근을 막았거나, 응답이 없다. */
export class AgentUnreachable extends Error {}
/** 에이전트는 떠 있지만 이번 요청이 기다릴 수 있는 시간을 넘겼다. */
export class AgentTimeout extends Error {}
/** 에이전트는 떠 있지만 토큰이 다르다 — compose.yml 을 다시 받아야 한다. */
export class AgentAuthError extends Error {}
/** 에이전트가 돌려준 2xx 가 아닌 응답. */
export class AgentHttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function agentFetch<T>(
  agentUrl: string,
  token: string,
  path: string,
  init: RequestInit & { timeoutMs?: number } = {},
): Promise<T> {
  const { timeoutMs = 4000, ...rest } = init;
  const headers = new Headers(rest.headers);
  headers.set("Authorization", `Bearer ${token}`);
  if (rest.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const outer = rest.signal;
  outer?.addEventListener("abort", () => controller.abort(), { once: true });
  let res: Response;
  try {
    res = await fetch(agentUrl + path, { ...rest, headers, signal: controller.signal });
  } catch (err) {
    if (timedOut) throw new AgentTimeout(`${Math.round(timeoutMs / 1000)}초 안에 응답이 없습니다`);
    throw new AgentUnreachable((err as Error).message);
  } finally {
    clearTimeout(timer);
  }
  if (res.status === 401) throw new AgentAuthError("토큰이 다릅니다");
  if (!res.ok) {
    let msg = `${res.status}`;
    try {
      msg = ((await res.json()) as { error?: string }).error ?? msg;
    } catch {
      /* 본문 없음 */
    }
    throw new AgentHttpError(res.status, msg);
  }
  return (await res.json()) as T;
}

export const agentStatus = (agentUrl: string, token: string, signal?: AbortSignal) =>
  agentFetch<AgentStatus>(agentUrl, token, "/api/status", { signal });

/** 응시 전 점검(엔진·Linux 컨테이너 모드·권한). docker 명령을 몇 개 부르므로 status 보다 넉넉히 기다린다. */
export const agentPreflight = (agentUrl: string, token: string, signal?: AbortSignal) =>
  agentFetch<Preflight>(agentUrl, token, "/api/preflight", { signal, timeoutMs: 25000 });

export type Step = { name: string; result: string; ms: number };
export type StepsResponse = { ok: boolean; steps: Step[] };

/** 환경 작업은 분 단위로 걸린다 — 넉넉히 기다린다. 에이전트는 같은 작업이 돌고 있으면 409 를 준다. */
const ENV_TIMEOUT_MS = 16 * 60 * 1000;
export const kindUp = (agentUrl: string, token: string, nodes: { control_planes: number; workers: number }) =>
  agentFetch<StepsResponse>(agentUrl, token, "/api/kind/up", { method: "POST", body: JSON.stringify(nodes), timeoutMs: ENV_TIMEOUT_MS });
export const kindDown = (agentUrl: string, token: string) =>
  agentFetch<StepsResponse>(agentUrl, token, "/api/kind/down", { method: "POST", timeoutMs: ENV_TIMEOUT_MS });
export const flociReset = (agentUrl: string, token: string) =>
  agentFetch<StepsResponse>(agentUrl, token, "/api/floci/reset", { method: "POST", timeoutMs: ENV_TIMEOUT_MS });

/** 서버의 준비 응답을 에이전트 /api/setup 에 넘긴다. Floci·kind 재생성과 setup 까지 분 단위다. */
export const prepareEnvironment = (
  agentUrl: string,
  token: string,
  prepare: {
    scenario_id: string;
    setup_reset: string;
    kind: { control_planes: number; workers: number } | null;
    setup: { command: string; scripts: Record<string, string>; timeout_seconds: number } | null;
    ai_rules: string;
  },
) =>
  agentFetch<StepsResponse>(agentUrl, token, "/api/setup", {
    method: "POST",
    timeoutMs: ENV_TIMEOUT_MS,
    body: JSON.stringify({
      scenario_id: prepare.scenario_id,
      reset: {
        floci: prepare.setup_reset === "floci" || prepare.setup_reset === "both",
        kind: prepare.setup_reset === "kind" || prepare.setup_reset === "both" ? prepare.kind : null,
      },
      setup: prepare.setup,
      ai_rules: prepare.ai_rules,
    }),
  });

/** 이 시나리오의 환경 준비가 되어 있는가 — 가벼운 /api/prepared 가 준비 표시가 없을 때만 404 를 준다. 그 밖의 오류(시간 초과·503·네트워크)는 던진다 — 「모름」이지 「준비 전」이 아니다. */
export async function isPrepared(agentUrl: string, token: string, scenarioId: string): Promise<boolean> {
  try {
    await agentFetch(agentUrl, token, `/api/prepared?scenario_id=${encodeURIComponent(scenarioId)}`, { timeoutMs: 15000 });
    return true;
  } catch (err) {
    if (err instanceof AgentHttpError && err.status === 404) return false;
    throw err;
  }
}

export type AgentTranscript = {
  tool: "claude" | "codex";
  since: string;
  truncated: boolean;
  error?: string;
  entries: { role: "user" | "assistant"; at: string; text: string }[];
};

/** 마지막 환경 준비 이후의 Claude·Codex 대화. 준비 표시가 없으면 AgentHttpError(404). */
export const fetchTranscript = (agentUrl: string, token: string, scenarioId: string) =>
  agentFetch<{ scenario_id: string; since: string; transcripts: AgentTranscript[] }>(
    agentUrl,
    token,
    `/api/ai-transcript?scenario_id=${encodeURIComponent(scenarioId)}`,
    { timeoutMs: 20000 },
  );

export type CheckResult = {
  id: string;
  name: string;
  hint: string;
  pass: boolean;
  output: string;
  truncated: boolean;
  exit_code: number;
  ms: number;
  error?: string;
};
export type CheckResponse = { agent_version: string; passed: number; total: number; results: CheckResult[] };

/** 검사 정의를 에이전트에 넘겨 workstation 에서 돌린다. 에이전트의 최악 소요(검사마다 timeout+2초, 스크립트
 *  설치·docker exec 오버헤드)보다 넉넉히 기다린다 — 시간을 넘긴 검사도 결과(증거)로 돌아와야 한다. */
export function runChecks(
  agentUrl: string,
  token: string,
  checks: { timeout_seconds: number }[],
  body: unknown,
): Promise<CheckResponse> {
  const budget = checks.reduce((sum, c) => sum + (c.timeout_seconds || 30) + 2, 0) * 1000 + 30000;
  return agentFetch<CheckResponse>(agentUrl, token, "/api/check", {
    method: "POST",
    body: JSON.stringify(body),
    timeoutMs: budget,
  });
}
