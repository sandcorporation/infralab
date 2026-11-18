import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { agentPreflight } from "../agent";
import { preflightGate, type Preflight } from "../exam";

export type PreflightState = {
  /** 점검 결과. agent 에 닿지 못했으면 null. */
  result: Preflight | null;
  checking: boolean;
  recheck: () => void;
};

/** agent GET /api/preflight 를 한 번 부른다(「다시 점검」으로 또). 주소·토큰이 없으면 점검하지 않는다. */
export function usePreflight(
  agentUrl: string | undefined,
  token: string | undefined,
): PreflightState {
  const [result, setResult] = useState<Preflight | null>(null);
  const [checking, setChecking] = useState(true);
  const [round, setRound] = useState(0);

  useEffect(() => {
    if (!agentUrl || !token) return;
    const controller = new AbortController();
    setChecking(true);
    agentPreflight(agentUrl, token, controller.signal)
      .then((r) => !controller.signal.aborted && setResult(r))
      .catch(() => !controller.signal.aborted && setResult(null))
      .finally(() => !controller.signal.aborted && setChecking(false));
    return () => controller.abort();
  }, [agentUrl, token, round]);

  const recheck = useCallback(() => setRound((n) => n + 1), []);
  return { result, checking, recheck };
}

/** 점검 결과 안내. 시험(exam)은 실패를 오류로, 연습(practice)은 경고로 보인다. 실패 항목마다 안내 링크. */
export function PreflightPanel({
  state,
  mode,
  cohortId,
}: {
  state: PreflightState;
  mode: "exam" | "practice";
  cohortId: number;
}) {
  const { result, checking, recheck } = state;
  if (checking)
    return (
      <p className="muted" role="status">
        응시 전 점검 중…
      </p>
    );
  const gate = preflightGate(result, mode);
  if (gate.warnings.length === 0)
    return (
      <p className="muted">
        응시 전 점검 통과 — Docker 엔진 · Linux 컨테이너 · 권한
      </p>
    );
  const failed = result?.checks.filter((c) => !c.ok) ?? [];
  return (
    <div className={mode === "exam" ? "error" : "notice"} role="alert">
      <p>
        {mode === "exam"
          ? "응시 전 점검을 통과해야 시작할 수 있습니다."
          : "응시 전 점검에 문제가 있습니다 — 연습은 할 수 있지만 실습이 제대로 돌지 않을 수 있습니다."}
      </p>
      <ul>
        {result === null ? (
          <li>
            {gate.warnings[0]}{" "}
            <Link to={`/cohorts/${cohortId}/setup`}>설치 안내</Link>
          </li>
        ) : failed.length === 0 ? (
          gate.warnings.map((w) => <li key={w}>{w}</li>)
        ) : (
          failed.map((c) => (
            <li key={c.id}>
              {c.message}{" "}
              {c.help_url && (
                <a href={c.help_url} target="_blank" rel="noreferrer">
                  안내
                </a>
              )}
            </li>
          ))
        )}
      </ul>
      <button className="secondary" onClick={recheck}>
        다시 점검
      </button>
    </div>
  );
}
