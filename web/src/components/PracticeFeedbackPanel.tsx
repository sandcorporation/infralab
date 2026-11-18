import { useEffect, useState } from "react";
import {
  ApiError,
  formatTime,
  getFeedbackQuota,
  getPracticeFeedback,
  requestPracticeFeedback,
  type FeedbackQuota,
  type PracticeFeedback,
} from "../api";
import { feedbackAction } from "../practice";

const LIMIT_MESSAGE = "오늘 피드백 5회를 다 썼습니다 — 내일 다시";
const GRADER_LABEL: Record<string, string> = { fake: "가짜 채점기", anthropic: "Anthropic" };

/** 연습 제출 하나의 결과 아래 — 기존 피드백·「피드백 받기」(남은 횟수)·다시 제출 안내·한도 소진 안내 중 하나. */
export function PracticeFeedbackPanel({ submission }: { submission: { id: number; has_transcript: boolean } }) {
  const [feedback, setFeedback] = useState<PracticeFeedback | null>(null);
  const [quota, setQuota] = useState<FeedbackQuota | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoaded(false);
    setFeedback(null);
    setError(null);
    Promise.all([
      submission.has_transcript ? getPracticeFeedback(submission.id) : Promise.resolve(null),
      getFeedbackQuota(),
    ])
      .then(([fb, q]) => {
        if (cancelled) return;
        setFeedback(fb);
        setQuota(q);
        setLoaded(true);
      })
      .catch((err: ApiError) => !cancelled && setError(`피드백을 읽지 못했습니다: ${err.message}`));
    return () => {
      cancelled = true;
    };
  }, [submission.id, submission.has_transcript]);

  async function ask() {
    setBusy(true);
    setError(null);
    try {
      setFeedback(await requestPracticeFeedback(submission.id));
    } catch (err) {
      const e = err as ApiError;
      setError(e.status === 429 ? LIMIT_MESSAGE : `피드백을 받지 못했습니다: ${e.message}`);
    } finally {
      setBusy(false);
      getFeedbackQuota()
        .then(setQuota)
        .catch(() => {
          /* 남은 횟수는 다음에 다시 읽는다 */
        });
    }
  }

  if (!loaded || !quota) return error ? <p className="error">{error}</p> : <p className="muted">피드백 확인 중…</p>;

  const action = feedbackAction({ has_transcript: submission.has_transcript, has_feedback: feedback !== null }, quota.remaining);

  return (
    <div>
      <h3 className="group-title">과정 피드백</h3>
      {action === "no_transcript" && <p className="muted">AI 대화 함께 제출을 켜고 다시 제출하세요</p>}
      {action === "limit_reached" && <p className="muted">{LIMIT_MESSAGE}</p>}
      {action === "request" && (
        <div className="row">
          <button onClick={ask} disabled={busy}>
            {busy ? "채점 중…" : "피드백 받기"}
          </button>
          <span className="muted">
            오늘 {quota.limit}회 중 {quota.remaining}회 남음
          </span>
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {action === "show" && feedback && (
        <>
          <p className="muted">
            {GRADER_LABEL[feedback.grader] ?? feedback.grader} · {formatTime(feedback.graded_at)}
          </p>
          <div className="sc-table-scroll">
            <table className="sc-table">
              <thead>
                <tr>
                  <th>항목</th>
                  <th>점수</th>
                  <th>근거 인용</th>
                </tr>
              </thead>
              <tbody>
                {feedback.items.map((item) => (
                  <tr key={item.key}>
                    <td>{item.label}</td>
                    <td>{item.score}/5</td>
                    <td>
                      {item.evidence.length === 0 ? (
                        <span className="muted">근거 없음</span>
                      ) : (
                        item.evidence.map((q, n) => (
                          <blockquote className="evidence" key={n}>
                            {q}
                          </blockquote>
                        ))
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
