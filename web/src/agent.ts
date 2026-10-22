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
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const outer = rest.signal;
  outer?.addEventListener("abort", () => controller.abort(), { once: true });
  let res: Response;
  try {
    res = await fetch(agentUrl + path, { ...rest, headers, signal: controller.signal });
  } catch (err) {
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
