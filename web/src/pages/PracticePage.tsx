import { useEffect, useState } from "react";
import { ApiError, getPractice, joinPractice, type PracticeStatus } from "../api";
import { PageHead, StatRow } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";
import { CohortView } from "./CohortPage";

// 개인 연습 화면. 참여 전이면 「연습 시작」, 참여 뒤엔 기수 화면과 같은 몸통(실습 환경·점검 경고·시나리오 목록).
export default function PracticePage() {
  const [status, setStatus] = useState<PracticeStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useCrumbs(status?.joined ? null : [{ label: "연습" }]);

  useEffect(() => {
    getPractice()
      .then(setStatus)
      .catch((err: ApiError) => setError(err.message));
  }, []);

  async function start() {
    setBusy(true);
    setError(null);
    try {
      await joinPractice();
      setStatus(await getPractice());
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (!status) return error ? <p className="error">{error}</p> : <p className="muted">불러오는 중…</p>;
  if (status.joined) return <CohortView cohortId={status.cohort_id} backTo="/practice" backLabel="연습" practice />;

  return <PracticeStart scenarioCount={status.scenario_count} busy={busy} error={error} onStart={start} />;
}

/** 참여 전 빈 상태: 열린 시나리오 수와 본문의 「연습 시작」. */
export function PracticeStart({
  scenarioCount,
  busy,
  error,
  onStart,
}: {
  scenarioCount: number;
  busy: boolean;
  error: string | null;
  onStart: () => void;
}) {
  return (
    <>
      <PageHead title="연습" />
      <section className="practice-start">
        <StatRow items={[{ label: "시나리오", value: scenarioCount }]} />
        <button onClick={onStart} disabled={busy}>
          {busy ? "시작하는 중…" : "연습 시작"}
        </button>
      </section>
      {error && <p className="error">{error}</p>}
    </>
  );
}
