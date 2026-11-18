import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ApiError, formatTime, instructor, parseId, type ExamReport, type ExamScore, type RubricItem } from "../api";

const STATUS_LABEL: Record<ExamReport["status"], string> = {
  invited: "초대됨",
  in_progress: "응시 중",
  finished: "끝남",
  revoked: "회수됨",
};
const HIDDEN_LABEL: Record<ExamScore["hidden_status"], string> = {
  done: "채점됨",
  pending: "결과 기다리는 중",
  skipped: "건너뜀",
};
const GRADER_LABEL: Record<string, string> = { fake: "가짜 채점기", anthropic: "Anthropic" };

/** 지원자 보고서 — 결과 점수, LLM 루브릭(점수·근거 인용), 담당자 수정 폼과 수정 이력. */
export default function InstructorExamReportPage() {
  const { id, inviteId } = useParams();
  const cohortId = parseId(id);
  const invite = parseId(inviteId);
  const [report, setReport] = useState<ExamReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<{ key: string; score: number; reason: string } | null>(null);

  useEffect(() => {
    if (cohortId === null || invite === null) return;
    let cancelled = false;
    instructor
      .examReport(cohortId, invite)
      .then((r) => !cancelled && setReport(r))
      .catch((e: ApiError) => !cancelled && setError(e.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId, invite]);

  if (cohortId === null || invite === null) return <p className="error">잘못된 주소입니다.</p>;

  async function run(fn: () => Promise<ExamReport>, what: string) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      setReport(await fn());
      setEditing(null);
    } catch (e) {
      setError(`${what} 실패: ${(e as ApiError).message}`);
    } finally {
      setBusy(false);
    }
  }

  const labelOf = (key: string) => report?.rubric?.items.find((i) => i.key === key)?.label ?? key;

  return (
    <>
      <p>
        <Link to={`/instructor/cohorts/${cohortId}`}>← 시험 회차</Link>
      </p>
      <h1>보고서 {report && `— ${report.label}`}</h1>
      {error && <p className="error">{error}</p>}
      {!report && !error && <p className="muted">불러오는 중…</p>}
      {report && (
        <>
          <section className="card">
            <h2>결과 점수</h2>
            <p>
              <span className="sc-badge sc-badge--neutral">{STATUS_LABEL[report.status]}</span>{" "}
              최종 {report.score.final_percent === null ? "—" : `${report.score.final_percent}%`} · 공개 검사{" "}
              {report.score.public_passed}/{report.score.public_total} · 숨은 검사{" "}
              {report.score.hidden_status === "skipped"
                ? HIDDEN_LABEL.skipped
                : `${report.score.hidden_passed}/${report.score.hidden_total} (${HIDDEN_LABEL[report.score.hidden_status]})`}
            </p>
            {report.local_model_unverified && <p className="warn">로컬 모델 — 조건 미검증</p>}
          </section>

          <section className="card">
            <h2>과정 루브릭</h2>
            <div className="row actions">
              <button
                disabled={busy}
                onClick={() => run(() => instructor.gradeExamReport(cohortId, invite), "채점")}
              >
                {report.rubric ? "다시 채점" : "채점"}
              </button>
              {report.rubric && (
                <span className="muted">
                  {GRADER_LABEL[report.rubric.grader] ?? report.rubric.grader} · {formatTime(report.rubric.graded_at)}
                </span>
              )}
            </div>
            {!report.rubric && <p className="muted">아직 채점하지 않았습니다.</p>}
            {report.rubric && (
              <div className="sc-table-scroll">
                <table className="sc-table">
                <thead>
                  <tr>
                    <th>항목</th>
                    <th>점수</th>
                    <th>LLM 점수</th>
                    <th>근거 인용</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {report.rubric.items.map((item: RubricItem) => (
                    <tr key={item.key}>
                      <td>{item.label}</td>
                      <td>
                        {item.score}/5 {item.edited && <span className="sc-badge sc-badge--neutral">수정됨</span>}
                      </td>
                      <td>{item.llm_score}/5</td>
                      <td>
                        {item.evidence.length === 0 ? (
                          <span className="muted">근거 없음</span>
                        ) : (
                          item.evidence.map((q, n) => <blockquote className="evidence" key={n}>{q}</blockquote>)
                        )}
                      </td>
                      <td className="right">
                        {editing?.key === item.key ? (
                          <form
                            onSubmit={(e) => {
                              e.preventDefault();
                              run(
                                () => instructor.editRubricItem(cohortId, invite, item.key, editing.score, editing.reason.trim()),
                                "점수 수정",
                              );
                            }}
                          >
                            <input
                              type="number"
                              min={0}
                              max={5}
                              aria-label={`${item.label} 점수`}
                              value={editing.score}
                              onChange={(e) => setEditing({ ...editing, score: Number(e.target.value) })}
                            />{" "}
                            <input
                              placeholder="사유"
                              aria-label={`${item.label} 수정 사유`}
                              value={editing.reason}
                              onChange={(e) => setEditing({ ...editing, reason: e.target.value })}
                            />{" "}
                            <button type="submit" disabled={busy || !editing.reason.trim()}>
                              저장
                            </button>{" "}
                            <button type="button" className="link" onClick={() => setEditing(null)}>
                              취소
                            </button>
                          </form>
                        ) : (
                          <button
                            className="link"
                            onClick={() => setEditing({ key: item.key, score: item.score, reason: "" })}
                          >
                            고치기
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
                </table>
              </div>
            )}
          </section>

          <section className="card">
            <h2>수정 이력 {report.edits.length}</h2>
            {report.edits.length === 0 ? (
              <p className="muted">수정 없음</p>
            ) : (
              <ol>
                {report.edits.map((e, n) => (
                  <li key={n}>
                    {formatTime(e.at)} {e.by} — {labelOf(e.key)} {e.from_score} → {e.to_score}: {e.reason}
                  </li>
                ))}
              </ol>
            )}
          </section>
        </>
      )}
    </>
  );
}
