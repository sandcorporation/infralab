import { useEffect, useState } from "react";
import { flociReset, kindDown, kindUp, type Step, type StepsResponse } from "../agent";
import type { Requires } from "../api";
import type { AgentProbe } from "./AgentStatusBadge";

type JobKind = "kind-up" | "kind-down" | "floci-reset";
type Outcome = { ok: boolean; steps: Step[]; label: string } | null;

const LABELS: Record<JobKind, string> = {
  "kind-up": "클러스터 올리기",
  "kind-down": "클러스터 내리기",
  "floci-reset": "Floci 초기화",
};

// 시나리오가 요구하는 환경을 버튼으로 올리고 내린다. kind 생성은 1~2분 걸린다 — 끝날 때까지 「올리는 중」을
// 보여 주고, 끝나면 단계별 결과·소요 시간을 그린다. 되돌리기 어려운 동작은 두 번 누른다.
export function EnvActions({
  requires,
  probe,
  agentUrl,
  token,
}: {
  requires: Requires;
  probe: AgentProbe;
  agentUrl: string;
  token: string;
}) {
  const [job, setJob] = useState<JobKind | null>(null);
  const [outcome, setOutcome] = useState<Outcome>(null);
  const [confirm, setConfirm] = useState<JobKind | null>(null);
  const [error, setError] = useState<string | null>(null);
  const connected = probe.state === "connected";
  const nodes = connected ? probe.status.kind_nodes.length : 0;
  const need = requires.kind ? requires.kind.control_planes + requires.kind.workers : 0;

  // 확인 중에 에이전트가 끊기면 확인을 접는다 — 보나마나 실패할 요청을 보내지 않게.
  useEffect(() => {
    if (!connected) setConfirm(null);
  }, [connected]);

  async function runJob(kind: JobKind, fn: () => Promise<StepsResponse>) {
    setJob(kind);
    setConfirm(null);
    setError(null);
    setOutcome(null);
    try {
      const res = await fn();
      setOutcome({ ok: res.ok, label: LABELS[kind], steps: res.steps });
    } catch (err) {
      setError(`${LABELS[kind]} 실패: ${(err as Error).message}`);
    } finally {
      setJob(null);
    }
  }

  if (!requires.kind && !requires.floci) return null;
  const idle = connected && job === null;
  return (
    <div className="env-actions">
      {requires.kind && (
        <div className="row">
          <button disabled={!idle} onClick={() => runJob("kind-up", () => kindUp(agentUrl, token, requires.kind!))}>
            {job === "kind-up" ? "올리는 중… (1~2분)" : nodes === 0 ? "클러스터 올리기" : nodes === need ? "클러스터 다시 확인" : `노드 ${need}개로 다시 만들기`}
          </button>
          {nodes > 0 &&
            (confirm === "kind-down" ? (
              <>
                <button className="danger" disabled={!idle} onClick={() => runJob("kind-down", () => kindDown(agentUrl, token))}>
                  내리기 확정
                </button>
                <button className="link" onClick={() => setConfirm(null)}>
                  취소
                </button>
              </>
            ) : (
              <button className="secondary" disabled={!idle} onClick={() => setConfirm("kind-down")}>
                클러스터 내리기
              </button>
            ))}
        </div>
      )}
      {requires.floci && (
        <div className="row">
          {confirm === "floci-reset" ? (
            <>
              <span className="muted">S3·EC2 등 Floci 의 모든 상태가 지워집니다.</span>
              <button className="danger" disabled={!idle} onClick={() => runJob("floci-reset", () => flociReset(agentUrl, token))}>
                초기화 확정
              </button>
              <button className="link" onClick={() => setConfirm(null)}>
                취소
              </button>
            </>
          ) : (
            <button className="secondary" disabled={!idle} onClick={() => setConfirm("floci-reset")}>
              {job === "floci-reset" ? "초기화 중…" : "Floci 초기화"}
            </button>
          )}
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {outcome && <StepsLog ok={outcome.ok} label={outcome.label} steps={outcome.steps} />}
    </div>
  );
}

/** 환경 작업의 단계별 결과 — 클러스터·Floci·환경 준비가 같은 틀을 쓴다. */
export function StepsLog({ ok, label, steps }: { ok: boolean; label: string; steps: Step[] }) {
  return (
    <details open={!ok} className="steps-log">
      <summary className={ok ? "ok" : "error"}>
        {label} {ok ? "완료" : "실패"}
      </summary>
      <ol>
        {steps.map((s) => (
          <li key={s.name} className={s.result.startsWith("ERROR") ? "error" : ""}>
            <strong>{s.name}</strong> <span className="muted">{Math.round(s.ms / 100) / 10}s</span>
            <pre>
              <code>{s.result}</code>
            </pre>
          </li>
        ))}
      </ol>
    </details>
  );
}
