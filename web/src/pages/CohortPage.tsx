import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  ApiError,
  formatTime,
  getCohortScenarios,
  getPracticeScenarios,
  parseId,
  type PracticeScenarioRow,
  type StudentScenarioSummary,
} from "../api";
import { AgentStatusBadge, useAgentProbe } from "../components/AgentStatusBadge";
import { PreflightPanel, usePreflight } from "../components/PreflightPanel";
import { RequiresTags } from "../components/ScenarioPicker";
import { useMyCohort } from "../hooks";

// 학생의 기수 화면. 환경(에이전트) 상태, 설치 안내 입구, 열린 시나리오 목록.
export default function CohortPage() {
  const { id } = useParams();
  return <CohortView cohortId={parseId(id)} backTo="/" backLabel="내 기수" />;
}

// 기수 화면의 몸통 — 연습 화면도 같은 것을 쓴다(연습 묶음은 기수와 같은 학생 경로를 쓴다).
export function CohortView({
  cohortId,
  backTo,
  backLabel,
  practice = false,
}: {
  cohortId: number | null;
  backTo: string;
  backLabel: string;
  practice?: boolean;
}) {
  const { cohort, error } = useMyCohort(cohortId);
  const probe = useAgentProbe(cohort?.agent_url, cohort?.agent_token);
  // 이 화면에서는 응시 전 점검을 경고로만 보인다(연습). 시험의 「시작」은 응시 화면이 점검으로 막는다.
  const preflight = usePreflight(cohort?.agent_url, cohort?.agent_token);
  const [scenarios, setScenarios] = useState<StudentScenarioSummary[] | null>(null);
  const [scenarioError, setScenarioError] = useState<string | null>(null);

  // 연습이면 시나리오마다 내 기록(최고 점수·제출 수·마지막 제출 시각).
  const [records, setRecords] = useState<Record<string, PracticeScenarioRow>>({});
  useEffect(() => {
    if (!practice) return;
    let cancelled = false;
    getPracticeScenarios()
      .then((rows) => !cancelled && setRecords(Object.fromEntries(rows.map((r) => [r.id, r]))))
      .catch(() => {
        /* 기록을 못 읽어도 목록은 보인다 */
      });
    return () => {
      cancelled = true;
    };
  }, [practice, cohortId]);

  useEffect(() => {
    setScenarios(null);
    setScenarioError(null);
    if (cohortId === null) return;
    let cancelled = false;
    getCohortScenarios(cohortId)
      .then((s) => !cancelled && setScenarios(s))
      .catch((err: ApiError) => !cancelled && setScenarioError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId]);

  if (error) return <p className="error">{error}</p>;
  if (!cohort) return <p className="muted">불러오는 중…</p>;

  const envProblems =
    probe.state === "connected"
      ? [
          probe.status.docker_error ? `Docker 에 닿지 못합니다: ${probe.status.docker_error}` : null,
          probe.status.workstation !== "running" ? `workstation 컨테이너: ${probe.status.workstation}` : null,
          probe.status.floci !== "running" ? `Floci 컨테이너: ${probe.status.floci}` : null,
        ].filter((x): x is string => x !== null)
      : [];

  return (
    <section>
      <p>
        <Link to={backTo}>← {backLabel}</Link>
      </p>
      <div className="row">
        <h1>{cohort.name}</h1>
        {cohort.archived && <span className="sc-badge sc-badge--neutral">보관됨</span>}
        <AgentStatusBadge probe={probe} />
      </div>

      <section className="card">
        <h2>내 실습 환경</h2>
        {(probe.state === "unreachable" || probe.state === "error") && (
          <p className="error">
            에이전트가 응답하지 않습니다. <Link to={`/cohorts/${cohort.id}/setup`}>설치 안내</Link>
          </p>
        )}
        {probe.state === "token-mismatch" && (
          <p className="error">
            에이전트 토큰이 다릅니다. <Link to={`/cohorts/${cohort.id}/setup`}>compose.yml 을 다시 받아</Link>{" "}
            <code>docker compose up -d</code> 를 다시 하세요.
          </p>
        )}
        {probe.state === "connected" && envProblems.length === 0 && (
          <p className="muted">
            에이전트 v{probe.status.version} · Docker {probe.status.docker_server} · workstation · Floci
            {probe.status.kind_nodes.length > 0 && ` · kind 노드 ${probe.status.kind_nodes.length}`}
          </p>
        )}
        {envProblems.length > 0 && (
          <ul className="error">
            {envProblems.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        )}
        {probe.state === "connected" && (
          <PreflightPanel state={preflight} mode="practice" cohortId={cohort.id} />
        )}
        <p>
          <Link className="button secondary" to={`/cohorts/${cohort.id}/setup`}>
            설치 안내 · compose.yml
          </Link>
        </p>
      </section>

      <section className="card">
        <h2>시나리오</h2>
        {scenarioError && <p className="error">{scenarioError}</p>}
        {scenarios && scenarios.length === 0 && <p className="muted">열린 시나리오가 없습니다.</p>}
        {scenarios && scenarios.length > 0 && (
          <ul className="list plain">
            {scenarios.map((s) => (
              <li key={s.id} className="row scenario-row">
                <Link to={`/cohorts/${cohort.id}/scenarios/${s.id}`}>
                  <strong>{s.title}</strong>
                </Link>
                <RequiresTags requires={s.requires} />
                <span className="grow" />
                {practice ? (
                  <>
                    <span className="muted small">
                      제출 {records[s.id]?.submission_count ?? 0}
                      {records[s.id]?.last_submitted_at && ` · ${formatTime(records[s.id].last_submitted_at as string)}`}
                    </span>
                    <span className={records[s.id]?.best_passed === s.total ? "score done" : "score"}>
                      {records[s.id]?.best_passed ?? "—"}/{s.total}
                    </span>
                  </>
                ) : (
                  <span className={s.passed === s.total ? "score done" : "score"}>
                    {s.passed === null ? "—" : s.passed}/{s.total}
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>
    </section>
  );
}
