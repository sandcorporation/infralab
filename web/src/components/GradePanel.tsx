import { useEffect, useState } from "react";
import { AgentTimeout, AgentUnreachable, runChecks, type CheckResult } from "../agent";
import { ApiError, formatTime, getLatestSubmission, submitResults, type ScenarioDetail, type Submission } from "../api";
import { GroupedCheckResultList } from "./CheckResultList";

type Phase =
  | { kind: "idle" }
  | { kind: "running" }
  | { kind: "uploading" }
  | { kind: "done"; submission: Submission }
  | { kind: "upload-failed"; reason: string };

type Shown = { results: CheckResult[]; agentVersion: string; passed: number; total: number };

// 채점 루프: 서버가 준 검사 정의 → 에이전트 /api/check → 결과를 그리고 → 같은 결과를 서버에 제출.
// 서버 올리기가 실패해도 결과는 화면에 남고 「다시 올리기」가 된다.
export function GradePanel({
  cohortId,
  scenario,
  agentUrl,
  agentToken,
  ready,
  lockedReason,
  onSubmitted,
}: {
  cohortId: number;
  scenario: ScenarioDetail;
  agentUrl: string;
  agentToken: string;
  ready: boolean;
  /** 막혀 있는 이유 — 채점 버튼 옆에 보인다. */
  lockedReason?: string;
  onSubmitted?: (s: Submission) => void;
}) {
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [shown, setShown] = useState<Shown | null>(null);
  const [latest, setLatest] = useState<Submission | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getLatestSubmission(cohortId, scenario.id)
      .then((s) => !cancelled && setLatest(s))
      .catch((err: ApiError) => !cancelled && setError(`최근 제출을 읽지 못했습니다: ${err.message}`));
    return () => {
      cancelled = true;
    };
  }, [cohortId, scenario.id]);

  async function upload(s: Shown) {
    setPhase({ kind: "uploading" });
    try {
      const submission = await submitResults(cohortId, scenario.id, {
        agent_version: s.agentVersion,
        results: s.results.map((r) => ({
          id: r.id,
          name: r.name,
          hint: r.hint,
          pass: r.pass,
          output: r.output,
          truncated: r.truncated,
          exit_code: r.exit_code,
          error: r.error ?? "",
        })),
      });
      setLatest(submission);
      setPhase({ kind: "done", submission });
      onSubmitted?.(submission);
    } catch (err) {
      setPhase({ kind: "upload-failed", reason: (err as ApiError).message });
    }
  }

  async function grade() {
    setError(null);
    setPhase({ kind: "running" });
    try {
      const res = await runChecks(agentUrl, agentToken, scenario.checks, {
        checks: scenario.checks,
        scripts: scenario.scripts,
      });
      const s: Shown = { results: res.results, agentVersion: res.agent_version, passed: res.passed, total: res.total };
      setShown(s);
      await upload(s);
    } catch (err) {
      setPhase({ kind: "idle" });
      if (err instanceof AgentTimeout) setError(`채점이 끝나지 않았습니다: ${err.message}`);
      else if (err instanceof AgentUnreachable) setError(`에이전트에 닿지 못했습니다: ${err.message}`);
      else setError((err as Error).message);
    }
  }

  const busy = phase.kind === "running" || phase.kind === "uploading";
  const hints = new Map(scenario.checks.map((c) => [c.id, c.hint]));
  const constraints = new Map(scenario.checks.map((c) => [c.id, !!c.constraint]));
  const hasConstraints = scenario.checks.some((c) => c.constraint);

  return (
    <>
      <div className="row">
        <h2>검사 {scenario.checks.length}</h2>
        <button onClick={grade} disabled={!ready || busy}>
          {phase.kind === "running" ? "채점 중…" : "채점"}
        </button>
        {lockedReason && <span className="muted">{lockedReason}</span>}
        {shown && (
          <span className={shown.passed === shown.total ? "score done" : "score"}>
            {shown.passed}/{shown.total}
          </span>
        )}
        {!shown && latest && (
          <span className="muted">
            최근 {latest.passed}/{latest.total} · {formatTime(latest.submitted_at)}
          </span>
        )}
      </div>
      {error && <p className="error">{error}</p>}
      {phase.kind === "uploading" && <p className="muted">결과 올리는 중…</p>}
      {phase.kind === "upload-failed" && (
        <p className="error">
          결과를 서버에 올리지 못했습니다 ({phase.reason}).{" "}
          <button className="link" onClick={() => shown && upload(shown)}>
            다시 올리기
          </button>
        </p>
      )}
      {phase.kind === "done" && <p className="notice">제출됨 · {formatTime(phase.submission.submitted_at)}</p>}

      {shown ? (
        <GroupedCheckResultList
          rows={shown.results.map((r) => ({
            key: r.id,
            name: r.name,
            pass: r.pass,
            output: r.output,
            truncated: r.truncated,
            error: r.error,
            meta: `${r.ms} ms`,
            hint: hints.get(r.id),
            constraint: constraints.get(r.id) ?? false,
          }))}
        />
      ) : (
        [false, true].map((isConstraint) => {
          const group = scenario.checks.filter((c) => !!c.constraint === isConstraint);
          if (group.length === 0) return null;
          return (
            <div key={String(isConstraint)}>
              {hasConstraints && <h3 className="group-title">{isConstraint ? "지켜야 할 것" : "해야 할 것"}</h3>}
              <ol className="checks">
                {group.map((c) => (
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
            </div>
          );
        })
      )}
    </>
  );
}
