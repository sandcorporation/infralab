import { useEffect, useState } from "react";
import { AgentAuthError, AgentUnreachable, agentStatus, type AgentStatus } from "../agent";

export type AgentProbe =
  | { state: "checking" }
  | { state: "connected"; status: AgentStatus }
  | { state: "unreachable"; reason: string }
  | { state: "token-mismatch" }
  | { state: "error"; reason: string };

/** 에이전트 status 를 주기적으로 쳐서 상태를 돌려준다. 한 번에 한 요청만 — 앞 요청이 끝나야 다음을 보낸다. */
export function useAgentProbe(agentUrl: string | undefined, token: string | undefined, intervalMs = 5000): AgentProbe {
  const [probe, setProbe] = useState<AgentProbe>({ state: "checking" });
  useEffect(() => {
    if (!agentUrl || !token) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    async function tick() {
      try {
        const status = await agentStatus(agentUrl!, token!, controller.signal);
        if (!controller.signal.aborted) setProbe({ state: "connected", status });
      } catch (err) {
        if (controller.signal.aborted) return;
        if (err instanceof AgentAuthError) setProbe({ state: "token-mismatch" });
        else if (err instanceof AgentUnreachable) setProbe({ state: "unreachable", reason: err.message });
        else setProbe({ state: "error", reason: (err as Error).message });
      }
      if (!controller.signal.aborted) timer = setTimeout(tick, intervalMs);
    }
    tick();
    return () => {
      controller.abort();
      if (timer) clearTimeout(timer);
    };
  }, [agentUrl, token, intervalMs]);
  return probe;
}

export function AgentStatusBadge({ probe }: { probe: AgentProbe }) {
  switch (probe.state) {
    case "checking":
      return <span className="sc-badge sc-badge--neutral">에이전트 확인 중…</span>;
    case "connected":
      return (
        <span className="sc-badge sc-badge--success" title={`docker ${probe.status.docker_server}`}>
          에이전트 연결됨 · v{probe.status.version}
        </span>
      );
    case "unreachable":
      return <span className="sc-badge sc-badge--danger">에이전트 없음</span>;
    case "token-mismatch":
      return <span className="sc-badge sc-badge--danger">토큰 불일치 — compose.yml 다시 받기</span>;
    case "error":
      return (
        <span className="sc-badge sc-badge--danger" title={probe.reason}>
          에이전트 오류: {probe.reason}
        </span>
      );
  }
}
