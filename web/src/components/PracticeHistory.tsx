import { useEffect, useState } from "react";
import {
  ApiError,
  formatTime,
  getPracticeHistory,
  getPracticeSubmission,
  type PracticeHistoryRow,
  type PracticeSubmissionDetail,
} from "../api";
import { CheckResultList } from "./CheckResultList";
import { PracticeFeedbackPanel } from "./PracticeFeedbackPanel";

/** 연습 시나리오 화면의 내 제출 이력 — 한 줄을 누르면 검사별 결과와 피드백. */
export function PracticeHistory({ scenarioId }: { scenarioId: string }) {
  const [rows, setRows] = useState<PracticeHistoryRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<number | null>(null);
  const [detail, setDetail] = useState<PracticeSubmissionDetail | null>(null);

  useEffect(() => {
    let cancelled = false;
    setRows(null);
    setError(null);
    setOpenId(null);
    getPracticeHistory(scenarioId)
      .then((r) => !cancelled && setRows(r))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [scenarioId]);

  useEffect(() => {
    setDetail(null);
    if (openId === null) return;
    let cancelled = false;
    getPracticeSubmission(openId)
      .then((d) => !cancelled && setDetail(d))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [openId]);

  return (
    <section className="card">
      <h2>내 제출 이력</h2>
      {error && <p className="error">{error}</p>}
      {rows && rows.length === 0 && <p className="muted">아직 제출이 없습니다.</p>}
      {rows && rows.length > 0 && (
        <ul className="list plain">
          {rows.map((h) => (
            <li key={h.id} className="row">
              <button className="secondary" onClick={() => setOpenId(openId === h.id ? null : h.id)}>
                {formatTime(h.submitted_at)}
              </button>
              <span className="score">
                {h.passed}/{h.total}
              </span>
              <span className="muted small">{h.has_feedback ? "피드백 있음" : "피드백 없음"}</span>
            </li>
          ))}
        </ul>
      )}
      {openId !== null && !detail && <p className="muted">불러오는 중…</p>}
      {detail && (
        <div>
          <h3 className="group-title">
            검사별 결과 · {detail.passed}/{detail.total}
          </h3>
          <CheckResultList
            rows={detail.results.map((r) => ({
              key: r.check_id,
              name: r.name,
              pass: r.pass,
              output: r.output,
              truncated: r.truncated,
              error: r.error,
            }))}
          />
          <PracticeFeedbackPanel submission={detail} />
        </div>
      )}
    </section>
  );
}
