import { useEffect, useState } from "react";
import { prepareEnvironment, type Step } from "../agent";
import { getPrepare, type Prepare } from "../api";
import type { AgentProbe } from "./AgentStatusBadge";
import { StepsLog } from "./EnvActions";

type Outcome = { ok: boolean; steps: Step[] } | null;

/** 진행 중에 보여 줄 예정 단계 이름 — 에이전트는 끝나야 단계별 결과를 준다. */
function plannedSteps(p: Prepare): string[] {
  const steps: string[] = [];
  if (p.setup_reset === "floci" || p.setup_reset === "both") steps.push("Floci 초기화");
  if (p.setup_reset === "kind" || p.setup_reset === "both") steps.push("클러스터 다시 만들기");
  steps.push("규칙 파일", "준비 표시");
  if (p.setup) steps.push("고장 내기");
  return steps;
}

// 「환경 준비」(고장 내기가 있는 시나리오) / 「시작」(없는 시나리오). 지금 환경이 지워지므로 두 번 눌러 확정한다.
export function PrepareButton({
  cohortId,
  scenarioId,
  probe,
  agentUrl,
  token,
  prepared,
  onPrepared,
}: {
  cohortId: number;
  scenarioId: string;
  probe: AgentProbe;
  agentUrl: string;
  token: string;
  prepared: boolean | null;
  onPrepared: (prepared: boolean | null) => void;
}) {
  const [plan, setPlan] = useState<Prepare | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [running, setRunning] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [outcome, setOutcome] = useState<Outcome>(null);
  const [error, setError] = useState<string | null>(null);
  const connected = probe.state === "connected";

  useEffect(() => {
    let cancelled = false;
    setPlan(null);
    setOutcome(null);
    setConfirm(false);
    getPrepare(cohortId, scenarioId)
      .then((p) => !cancelled && setPlan(p))
      .catch((err: Error) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId, scenarioId]);

  useEffect(() => {
    if (!connected) setConfirm(false);
  }, [connected]);

  useEffect(() => {
    if (!running) return;
    setElapsed(0);
    const t = setInterval(() => setElapsed((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [running]);

  async function run() {
    setConfirm(false);
    setRunning(true);
    setError(null);
    setOutcome(null);
    try {
      // 눌린 순간의 최신 준비 응답을 쓴다 — 강사가 시나리오를 고쳤을 수 있다.
      const fresh = await getPrepare(cohortId, scenarioId);
      setPlan(fresh);
      const res = await prepareEnvironment(agentUrl, token, fresh);
      setOutcome({ ok: res.ok, steps: res.steps });
      onPrepared(res.ok);
    } catch (err) {
      setError(`${plan?.setup ? "환경 준비" : "시작"} 실패: ${(err as Error).message}`);
      onPrepared(null); // 결과를 모른다 — 다시 물어 본다
    } finally {
      setRunning(false);
    }
  }

  if (!plan) return error ? <p className="error">{error}</p> : null;
  const label = plan.setup ? "환경 준비" : "시작";
  const idle = connected && !running;
  return (
    <div className="env-actions prepare">
      <div className="row">
        {confirm ? (
          <>
            <span className="muted">지금 환경이 지워집니다.</span>
            <button className="danger" disabled={!idle} onClick={run}>
              {label} 확정
            </button>
            <button className="link" onClick={() => setConfirm(false)}>
              취소
            </button>
          </>
        ) : (
          <button disabled={!idle} onClick={() => setConfirm(true)}>
            {running ? `${label} 중… ${elapsed}s` : prepared ? `${label} 다시` : label}
          </button>
        )}
        {prepared && !running && <span className="badge ok">준비됨</span>}
      </div>
      {running && (
        <ol className="muted planned">
          {plannedSteps(plan).map((n) => (
            <li key={n}>{n}</li>
          ))}
        </ol>
      )}
      {error && <p className="error">{error}</p>}
      {outcome && <StepsLog ok={outcome.ok} label={label} steps={outcome.steps} />}
    </div>
  );
}
