import { useEffect, useState } from "react";
import type { ApiError } from "../api";
import { BUCKET_LABELS, bucketHeights, getExamDashboard, type ExamDashboardRow } from "../exam";

// 시험 대시보드 탭 — 시험 회차마다 초대·시작·완료 수와 최종 점수 분포 막대.
export default function InstructorExamDashboardPage() {
  const [rows, setRows] = useState<ExamDashboardRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getExamDashboard()
      .then(setRows)
      .catch((err) => setError((err as ApiError).message));
  }, []);

  return (
    <section>
      <h1>시험 대시보드</h1>
      {error && <p className="error">{error}</p>}
      {rows === null && !error && <p className="muted">불러오는 중…</p>}
      {rows?.length === 0 && <p className="muted">시험 회차가 없습니다.</p>}
      {rows && rows.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
          <thead>
            <tr>
              <th>회차</th>
              <th>초대</th>
              <th>시작</th>
              <th>완료</th>
              <th>점수 분포</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const heights = bucketHeights(r.score_buckets);
              return (
                <tr key={r.cohort_id}>
                  <td>{r.name}</td>
                  <td>{r.invited}</td>
                  <td>{r.started}</td>
                  <td>{r.finished}</td>
                  <td>
                    <div className="dist" role="img" aria-label={`점수 분포 ${BUCKET_LABELS.map((l, i) => `${l}점 ${r.score_buckets[i]}명`).join(", ")}`}>
                      {heights.map((h, i) => (
                        <div key={BUCKET_LABELS[i]} className="bar" title={`${BUCKET_LABELS[i]}: ${r.score_buckets[i]}`}>
                          <i style={{ height: `${Math.round(h * 100)}%` }} />
                          <span>{BUCKET_LABELS[i]}</span>
                        </div>
                      ))}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
