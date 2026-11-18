import { useEffect, useState } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import {
  ApiError,
  formatTime,
  instructor,
  parseId,
  type ExamEvent,
  type ExamReport,
  type ExamScore,
  type RubricItem,
} from "../api";
import { SIGNAL_LABEL } from "../components/ExamPanel";
import { ButtonTabs, Modal, PageHead, StatRow } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";

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

type ReportTab = "result" | "rubric" | "proctor" | "edits";
const TABS: ReportTab[] = ["result", "rubric", "proctor", "edits"];

/** 지원자 보고서 — 요약 타일 한 줄 + 탭(결과 · 루브릭 · 감독 · 이력). 탭은 ?tab= 으로 URL 에 남는다. */
export default function InstructorExamReportPage() {
  const { id, inviteId } = useParams();
  const cohortId = parseId(id);
  const invite = parseId(inviteId);
  const [params, setParams] = useSearchParams();
  const tab: ReportTab = TABS.includes(params.get("tab") as ReportTab) ? (params.get("tab") as ReportTab) : "result";
  const [report, setReport] = useState<ExamReport | null>(null);
  const [events, setEvents] = useState<ExamEvent[] | null>(null);
  const [cohortName, setCohortName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<{ item: RubricItem; score: number; reason: string } | null>(null);

  useEffect(() => {
    if (cohortId === null || invite === null) return;
    let cancelled = false;
    instructor
      .examReport(cohortId, invite)
      .then((r) => !cancelled && setReport(r))
      .catch((e: ApiError) => !cancelled && setError(e.message));
    instructor
      .examEvents(cohortId, invite)
      .then((r) => !cancelled && setEvents(r))
      .catch(() => !cancelled && setEvents(null));
    instructor
      .cohort(cohortId)
      .then((c) => !cancelled && setCohortName(c.name))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [cohortId, invite]);

  useCrumbs([
    { label: "기수", to: "/instructor" },
    { label: cohortName ?? "…", to: `/instructor/cohorts/${cohortId}/invites` },
    { label: report?.label ?? "보고서" },
  ]);

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
  const setTab = (t: ReportTab) =>
    setParams(
      (p) => {
        if (t === "result") p.delete("tab");
        else p.set("tab", t);
        return p;
      },
      { replace: true },
    );

  if (!report) return error ? <p className="error">{error}</p> : <p className="muted">불러오는 중…</p>;
  const score = report.score;
  const rubricSum = report.rubric?.items.reduce((n, i) => n + i.score, 0);
  const hidden = score.hidden_status === "skipped" ? "—" : `${score.hidden_passed}/${score.hidden_total}`;

  return (
    <>
      <PageHead
        title={report.label}
        badges={
          <>
            <span className="sc-badge sc-badge--neutral">{STATUS_LABEL[report.status]}</span>
            {report.local_model_unverified && <span className="sc-badge sc-badge--warning">로컬 모델 — 조건 미검증</span>}
          </>
        }
        sub={report.rubric ? `${GRADER_LABEL[report.rubric.grader] ?? report.rubric.grader} · ${formatTime(report.rubric.graded_at)}` : undefined}
        actions={
          <button disabled={busy} onClick={() => run(() => instructor.gradeExamReport(cohortId, invite), "채점")}>
            {busy ? "채점 중…" : report.rubric ? "다시 채점" : "루브릭 채점"}
          </button>
        }
      />
      {error && <p className="error">{error}</p>}
      <StatRow
        items={[
          { label: <FinalLabel score={score} />, value: score.final_percent === null ? "—" : `${score.final_percent}%` },
          { label: "공개 검사", value: `${score.public_passed}/${score.public_total}` },
          { label: "숨은 검사", value: hidden, note: score.hidden_status === "done" ? undefined : HIDDEN_LABEL[score.hidden_status] },
          {
            label: "루브릭",
            value: report.rubric ? `${rubricSum}/${report.rubric.items.length * 5}` : "—",
          },
          { label: "감독 신호", value: events ? events.length : "—" },
          { label: "수정", value: report.edits.length },
        ]}
      />
      <ButtonTabs
        label="보고서"
        idPrefix="report"
        value={tab}
        onChange={setTab}
        items={[
          { key: "result", label: "결과" },
          { key: "rubric", label: "루브릭", count: report.rubric?.items.length },
          { key: "proctor", label: "감독", count: events?.length },
          { key: "edits", label: "이력", count: report.edits.length },
        ]}
      />

      {tab === "result" && (
        <div role="tabpanel" id="report-panel-result" aria-labelledby="report-tab-result">
          <div className="sc-table-scroll">
            <table className="sc-table app-table-fit">
              <thead>
                <tr>
                  <th>구분</th>
                  <th className="sc-num">통과</th>
                  <th>상태</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>공개 검사</td>
                  <td className="sc-num">
                    {score.public_passed}/{score.public_total}
                  </td>
                  <td>
                    <span className="sc-badge sc-badge--neutral">{STATUS_LABEL[report.status]}</span>
                  </td>
                </tr>
                <tr>
                  <td>숨은 검사</td>
                  <td className="sc-num">{score.hidden_status === "skipped" ? "—" : `${score.hidden_passed}/${score.hidden_total}`}</td>
                  <td>
                    <span className="sc-badge sc-badge--neutral">{HIDDEN_LABEL[score.hidden_status]}</span>
                  </td>
                </tr>
                <tr>
                  <td>
                    <strong>
                      <FinalLabel score={score} />
                    </strong>
                  </td>
                  <td className="sc-num">
                    <strong>{score.final_percent === null ? "—" : `${score.final_percent}%`}</strong>
                  </td>
                  <td />
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "rubric" && (
        <div role="tabpanel" id="report-panel-rubric" aria-labelledby="report-tab-rubric">
          {!report.rubric && <p className="muted">아직 채점하지 않았습니다.</p>}
          {report.rubric && (
            <div className="sc-table-scroll">
              <table className="sc-table">
                <thead>
                  <tr>
                    <th>항목</th>
                    <th className="sc-num">점수</th>
                    <th className="sc-num">LLM 점수</th>
                    <th>근거 인용</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {report.rubric.items.map((item: RubricItem) => (
                    <tr key={item.key}>
                      <td>{item.label}</td>
                      <td className="sc-num nowrap">
                        {item.score}/5 {item.edited && <span className="sc-badge sc-badge--neutral">수정됨</span>}
                      </td>
                      <td className="sc-num">{item.llm_score}/5</td>
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
                      <td className="right">
                        <button className="link" onClick={() => setEditing({ item, score: item.score, reason: "" })}>
                          고치기
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {tab === "proctor" && (
        <div role="tabpanel" id="report-panel-proctor" aria-labelledby="report-tab-proctor">
          {events === null && <p className="muted">감독 기록을 읽지 못했습니다.</p>}
          {events?.length === 0 && <p className="muted">감독 신호 없음</p>}
          {events && events.length > 0 && (
            <ol className="events">
              {events.map((e, n) => (
                <li key={n}>
                  <span className="muted">{formatTime(e.at)}</span> {SIGNAL_LABEL[e.kind] ?? e.kind}
                  {e.detail && ` — ${e.detail}`}
                </li>
              ))}
            </ol>
          )}
        </div>
      )}

      {tab === "edits" && (
        <div role="tabpanel" id="report-panel-edits" aria-labelledby="report-tab-edits">
          {report.edits.length === 0 ? (
            <p className="muted">수정 없음</p>
          ) : (
            <ol className="events">
              {report.edits.map((e, n) => (
                <li key={n}>
                  <span className="muted">{formatTime(e.at)}</span> {e.by} — {labelOf(e.key)} {e.from_score} → {e.to_score}: {e.reason}
                </li>
              ))}
            </ol>
          )}
        </div>
      )}

      <Modal
        open={editing !== null}
        title={`점수 고치기 · ${editing?.item.label ?? ""}`}
        onClose={() => setEditing(null)}
        foot={
          <>
            <button type="button" className="secondary" onClick={() => setEditing(null)}>
              취소
            </button>
            <button type="submit" form="rubric-edit" disabled={busy || !editing?.reason.trim()}>
              저장
            </button>
          </>
        }
      >
        {editing && (
          <form
            id="rubric-edit"
            className="stack"
            onSubmit={(e) => {
              e.preventDefault();
              void run(
                () => instructor.editRubricItem(cohortId, invite, editing.item.key, editing.score, editing.reason.trim()),
                "점수 수정",
              );
            }}
          >
            <label>
              점수 (0–5)
              <input
                type="number"
                min={0}
                max={5}
                value={editing.score}
                onChange={(e) => setEditing({ ...editing, score: Number(e.target.value) })}
              />
            </label>
            <label>
              사유
              <input value={editing.reason} onChange={(e) => setEditing({ ...editing, reason: e.target.value })} />
            </label>
            {error && <p className="error">{error}</p>}
          </form>
        )}
      </Modal>
    </>
  );
}

/** 최종 점수 라벨 — 검사(공개+숨은)만으로 셈한다. 루브릭은 따로 타일. 계산식은 툴팁(#154). */
export function FinalLabel({ score }: { score: ExamScore }) {
  const hp = score.hidden_status === "done" ? score.hidden_passed : 0;
  const ht = score.hidden_status === "skipped" ? 0 : score.hidden_total;
  const formula =
    `(공개 ${score.public_passed} + 숨은 ${hp}) ÷ (공개 ${score.public_total} + 숨은 ${ht}) — 공개·숨은 검사 통과 비율, 루브릭 제외` +
    (score.hidden_status === "pending" ? " · 숨은 검사 결과를 기다리는 중" : "");
  return <span title={formula}>최종(검사)</span>;
}
