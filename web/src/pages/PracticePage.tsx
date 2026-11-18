import { useEffect, useState } from "react";
import { ApiError, getPractice, joinPractice, type PracticeStatus } from "../api";
import { CohortView } from "./CohortPage";

// 개인 연습 화면. 참여 전이면 「연습 시작」, 참여 뒤엔 기수 화면과 같은 몸통(실습 환경·점검 경고·시나리오 목록).
export default function PracticePage() {
  const [status, setStatus] = useState<PracticeStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

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
  if (status.joined) return <CohortView cohortId={status.cohort_id} backTo="/practice" backLabel="연습" />;

  return (
    <section className="card narrow">
      <h1>연습</h1>
      <p className="muted">모든 시나리오를 내 환경에서 풀고 결과를 확인합니다. 수업이 없어도 시작할 수 있습니다.</p>
      <button onClick={start} disabled={busy}>
        {busy ? "시작하는 중…" : "연습 시작"}
      </button>
      {error && <p className="error">{error}</p>}
    </section>
  );
}
