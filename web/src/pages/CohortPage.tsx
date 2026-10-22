import { Link, useParams } from "react-router-dom";
import { parseId } from "../api";
import { AgentStatusBadge, useAgentProbe } from "../components/AgentStatusBadge";
import { useMyCohort } from "../hooks";

// 학생의 기수 화면. 환경(에이전트) 상태와 설치 안내 입구. 시나리오 목록은 #9 에서 여기에 들어온다.
export default function CohortPage() {
  const { id } = useParams();
  const { cohort, error } = useMyCohort(parseId(id));
  const probe = useAgentProbe(cohort?.agent_url, cohort?.agent_token);

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
        <Link to="/">← 내 기수</Link>
      </p>
      <div className="row">
        <h1>{cohort.name}</h1>
        {cohort.archived && <span className="tag">보관됨</span>}
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
        <p>
          <Link className="button secondary" to={`/cohorts/${cohort.id}/setup`}>
            설치 안내 · compose.yml
          </Link>
        </p>
      </section>

      <section className="card">
        <h2>시나리오</h2>
        <p className="muted">열린 시나리오가 없습니다.</p>
      </section>
    </section>
  );
}
