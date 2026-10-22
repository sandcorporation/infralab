import { useEffect, useState } from "react";
import Markdown from "react-markdown";
import { Link, useParams } from "react-router-dom";
import { ApiError, getCohortScenario, parseId, type ScenarioDetail } from "../api";
import { AgentStatusBadge, useAgentProbe } from "../components/AgentStatusBadge";
import { EnvCheck, envVerdict } from "../components/EnvCheck";
import { RequiresTags } from "../components/ScenarioPicker";
import { useMyCohort } from "../hooks";

export default function ScenarioPage() {
  const { id, scenarioId = "" } = useParams();
  const cohortId = parseId(id);
  const { cohort, error: cohortError } = useMyCohort(cohortId);
  const [scenario, setScenario] = useState<ScenarioDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const probe = useAgentProbe(cohort?.agent_url, cohort?.agent_token);

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

  if (cohortError || error) return <p className="error">{cohortError ?? error}</p>;
  if (!cohort || !scenario) return <p className="muted">불러오는 중…</p>;
  const env = envVerdict(probe, scenario.requires);

  return (
    <section className="scenario">
      <p>
        <Link to={`/cohorts/${cohort.id}`}>← {cohort.name}</Link>
      </p>
      <div className="row">
        <h1>{scenario.title}</h1>
        <RequiresTags requires={scenario.requires} />
        <AgentStatusBadge probe={probe} />
      </div>

      <div className="scenario-grid">
        <div>
          <section className="card markdown">
            <Markdown>{scenario.description}</Markdown>
          </section>

          <section className="card">
            <div className="row">
              <h2>검사 {scenario.checks.length}</h2>
              <button disabled title="채점은 다음 단계에서 열립니다">
                채점
              </button>
            </div>
            <EnvCheck cohortId={cohort.id} probe={probe} requires={scenario.requires} />
            <ol className="checks">
              {scenario.checks.map((c) => (
                <li key={c.id}>
                  <div>{c.name}</div>
                  {c.hint && (
                    <div className="muted hint">
                      <code>{c.hint}</code>
                    </div>
                  )}
                </li>
              ))}
            </ol>
          </section>
        </div>

        <aside>
          <section className="card">
            <h2>환경</h2>
            {scenario.requires.kind && (
              <p className="muted">
                kind {scenario.requires.kind.control_planes}cp + {scenario.requires.kind.workers}w
                {probe.state === "connected" && ` · 노드 ${probe.status.kind_nodes.length}`}
              </p>
            )}
            {scenario.requires.floci && <p className="muted">Floci{probe.state === "connected" && ` · ${probe.status.floci}`}</p>}
            {env.ready && <p className="badge ok">준비됨</p>}
          </section>
          <section className="card terminal-placeholder">
            <h2>터미널</h2>
            <p className="muted">다음 단계에서 열립니다.</p>
          </section>
        </aside>
      </div>
    </section>
  );
}
