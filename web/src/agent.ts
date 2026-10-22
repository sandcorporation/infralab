// 학생 PC 의 로컬 에이전트(127.0.0.1:7777) 클라이언트. 서버와는 별개의 오리진이라 fetch 가 CORS 를 탄다 —
// 에이전트는 대시보드 오리진에서 온 요청에만 헤더를 준다.

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
    throw new Error(msg);
  }
  return (await res.json()) as T;
}

export const agentStatus = (agentUrl: string, token: string, signal?: AbortSignal) =>
  agentFetch<AgentStatus>(agentUrl, token, "/api/status", { signal });

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
