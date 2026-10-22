import { Link } from "react-router-dom";
import type { Requires } from "../api";
import type { AgentProbe } from "./AgentStatusBadge";

export type EnvVerdict = { ready: boolean; missing: string[] };

/** 시나리오가 요구하는 환경이 다 있는지. 에이전트 status 와 requires 를 견준다. */
export function envVerdict(probe: AgentProbe, requires: Requires): EnvVerdict {
  if (probe.state === "checking") return { ready: false, missing: [] };
  if (probe.state === "unreachable" || probe.state === "error") return { ready: false, missing: ["에이전트"] };
  if (probe.state === "token-mismatch") return { ready: false, missing: ["에이전트 토큰"] };
  const s = probe.status;
  // Docker 자체가 죽었으면 컨테이너 상태는 전부 missing 으로 보인다 — Docker 하나만 말한다.
  if (s.docker_error) return { ready: false, missing: ["Docker"] };
  const missing: string[] = [];
  if (s.workstation !== "running") missing.push("workstation");
  if (requires.floci && s.floci !== "running") missing.push("Floci");
  if (requires.kind) {
    const need = requires.kind.control_planes + requires.kind.workers;
    if (s.kind_nodes.length < need) missing.push("kind 클러스터");
  }
  return { ready: missing.length === 0, missing };
}

export function EnvCheck({ cohortId, probe, requires }: { cohortId: number; probe: AgentProbe; requires: Requires }) {
  const v = envVerdict(probe, requires);
  if (probe.state === "checking") return <p className="muted">환경 확인 중…</p>;
  if (v.ready) return null;
  return (
    <div className="env-missing">
      <p className="error">빠진 것: {v.missing.join(", ")}</p>
      {(v.missing.includes("에이전트") || v.missing.includes("에이전트 토큰") || v.missing.includes("Docker")) && (
        <p>
          <Link to={`/cohorts/${cohortId}/setup`}>설치 안내</Link>
        </p>
      )}
      {(v.missing.includes("workstation") || v.missing.includes("Floci")) && (
        <p>
          compose 폴더에서 <code>docker compose up -d</code>
        </p>
      )}
      {v.missing.includes("kind 클러스터") && <p>아래 「클러스터 올리기」</p>}
    </div>
  );
}
