import { useEffect, useState } from "react";
import Markdown from "react-markdown";
import { Link, useParams } from "react-router-dom";
import { ApiError, getCohortScenario, getPractice, parseId, type ScenarioDetail } from "../api";
import { AgentStatusBadge, useAgentProbe } from "../components/AgentStatusBadge";
import { isPrepared } from "../agent";
import { EnvActions } from "../components/EnvActions";
import { PracticeHistory } from "../components/PracticeHistory";
import { PrepareButton } from "../components/PrepareButton";
import { EnvCheck, envVerdict } from "../components/EnvCheck";
import { GradePanel } from "../components/GradePanel";
import { RequiresTags } from "../components/ScenarioPicker";
import { Terminal } from "../components/Terminal";
import { useMyCohort } from "../hooks";
import { useExamClock } from "../examAttempt";

export default function ScenarioPage() {
  const { id, scenarioId = "" } = useParams();
  const cohortId = parseId(id);
  const { cohort, error: cohortError } = useMyCohort(cohortId);
  const [scenario, setScenario] = useState<ScenarioDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const probe = useAgentProbe(cohort?.agent_url, cohort?.agent_token);
  const exam = useExamClock();
  // 연습 묶음이면 채점 결과 아래에 과정 피드백을 보인다.
  const [isPractice, setIsPractice] = useState(false);
  useEffect(() => {
    let cancelled = false;
    getPractice()
      .then((p) => !cancelled && setIsPractice(p.cohort_id === cohortId))
      .catch(() => !cancelled && setIsPractice(false));
    return () => {
      cancelled = true;
    };
  }, [cohortId]);
  const examEnded = exam?.status?.cohort_id === cohortId && exam.finished;
  // 터미널은 에이전트에 한 번 붙은 뒤로는 상태 폴링 한 번의 실패로 떼지 않는다 — 떼면 셸과 거기서 돌던 명령이
  // 죽는다. 끊김은 터미널 자신이 보여 주고 재연결한다.
  const [agentSeen, setAgentSeen] = useState(false);
  useEffect(() => {
    if (probe.state === "connected") setAgentSeen(true);
  }, [probe.state]);

  // 환경 준비 여부 — null 이면 아직 모른다. 에이전트의 기록 API 가 준비 표시가 없으면 404 를 주는 것을 그대로 쓴다.
  const [prepared, setPrepared] = useState<boolean | null>(null);
  useEffect(() => {
    setPrepared(null);
  }, [cohortId, scenarioId]);
  const connected = probe.state === "connected";
  // 404(준비 표시 없음)만 「준비 전」이다. 시간 초과·503·네트워크 오류는 모르는 채로 두고 5초 뒤에 다시 묻는다 —
  // 한 번의 실패가 새로고침 전까지 채점을 잠그지 않게.
  const [askAgain, setAskAgain] = useState(0);
  useEffect(() => {
    if (!connected || prepared !== null || !cohort) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    isPrepared(cohort.agent_url, cohort.agent_token, scenarioId)
      .then((p) => !cancelled && setPrepared(p))
      .catch(() => {
        if (!cancelled) timer = setTimeout(() => setAskAgain((n) => n + 1), 5000);
      });
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [connected, prepared, cohort, scenarioId, askAgain]);

  useEffect(() => {
    if (cohortId === null) return;
    let cancelled = false;
    setScenario(null);
    setError(null);
    getCohortScenario(cohortId, scenarioId)
      .then((s) => !cancelled && setScenario(s))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId, scenarioId]);

  if (cohortError) return <p className="error">{cohortError}</p>;
  if (!cohort) return <p className="muted">불러오는 중…</p>;
  const env = scenario ? envVerdict(probe, scenario.requires) : null;

  return (
    <section className="scenario">
      <p>
        <Link to={`/cohorts/${cohort.id}`}>← {cohort.name}</Link>
      </p>
      <div className="row">
        <h1>{scenario?.title ?? "…"}</h1>
        {scenario && <RequiresTags requires={scenario.requires} />}
        <AgentStatusBadge probe={probe} />
      </div>

      <div className="scenario-grid">
        <div>
          {error && <p className="error">{error}</p>}
          {!error && !scenario && <p className="muted">불러오는 중…</p>}
          {scenario && (
            <>
              <section className="card markdown">
                <Markdown>{scenario.description}</Markdown>
              </section>
              <section className="card">
                <EnvCheck cohortId={cohort.id} probe={probe} requires={scenario.requires} />
                <GradePanel
                  cohortId={cohort.id}
                  scenario={scenario}
                  agentUrl={cohort.agent_url}
                  agentToken={cohort.agent_token}
                  ready={(env?.ready ?? false) && prepared === true && !examEnded}
                  practice={isPractice}
                  lockedReason={examEnded ? "시험 마감" : env?.ready ? (prepared === false ? "환경 준비 먼저" : prepared === null ? "준비 확인 중…" : undefined) : undefined}
                />
              </section>
              {isPractice && <PracticeHistory scenarioId={scenario.id} />}
            </>
          )}
        </div>

        {/* 사이드는 시나리오가 아니라 기수(에이전트)에 매인다 — 시나리오를 바꿔도 셸은 살아 있다. */}
        <aside>
          {scenario && (
            <section className="card">
              <h2>환경</h2>
              {scenario.requires.kind && (
                <p className="muted">
                  kind {scenario.requires.kind.control_planes}cp + {scenario.requires.kind.workers}w
                  {probe.state === "connected" && ` · 노드 ${probe.status.kind_nodes.length}`}
                </p>
              )}
              {scenario.requires.floci && (
                <p className="muted">Floci{probe.state === "connected" && ` · ${probe.status.floci}`}</p>
              )}
              {env?.ready && <p className="sc-badge sc-badge--success">환경 있음</p>}
              <PrepareButton
                cohortId={cohort.id}
                scenarioId={scenario.id}
                probe={probe}
                agentUrl={cohort.agent_url}
                token={cohort.agent_token}
                prepared={prepared}
                onPrepared={setPrepared}
              />
              <EnvActions requires={scenario.requires} probe={probe} agentUrl={cohort.agent_url} token={cohort.agent_token} />
            </section>
          )}
          <section className="card">
            <h2>터미널</h2>
            {agentSeen ? (
              <Terminal key={cohort.id} agentUrl={cohort.agent_url} token={cohort.agent_token} />
            ) : (
              <p className="muted">
                에이전트가 연결되면 열립니다. <Link to={`/cohorts/${cohort.id}/setup`}>설치 안내</Link>
              </p>
            )}
          </section>
        </aside>
      </div>
    </section>
  );
}
