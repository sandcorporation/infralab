import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import type { ApiError } from "../api";
import { PageHead, StatRow } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";
import { BUCKET_LABELS, bucketHeights, getExamDashboard, type ExamDashboardRow } from "../exam";

// 시험 대시보드 탭 — 시험 회차마다 초대·시작·완료 수와 최종 점수 분포 막대.
export default function InstructorExamDashboardPage() {
  const [rows, setRows] = useState<ExamDashboardRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const navigate = useNavigate();
  useCrumbs([{ label: "시험" }]);

  useEffect(() => {
    getExamDashboard()
      .then(setRows)
      .catch((err) => setError((err as ApiError).message));
  }, []);

  const sum = (k: "invited" | "started" | "finished") => (rows ? rows.reduce((n, r) => n + r[k], 0) : "—");
  return (
    <>
      <PageHead title="시험" />
      <StatRow
        items={[
          { label: "회차", value: rows ? rows.length : "—" },
          { label: "초대", value: sum("invited") },
          { label: "시작", value: sum("started") },
          { label: "완료", value: sum("finished") },
        ]}
      />
      {error && <p className="error">{error}</p>}
      {rows === null && !error && <p className="muted">불러오는 중…</p>}
      {rows?.length === 0 && <p className="muted">시험 회차가 없습니다.</p>}
      {rows && rows.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
          <thead>
            <tr>
              <th>회차</th>
              <th className="sc-num">초대</th>
              <th className="sc-num">시작</th>
              <th className="sc-num">완료</th>
              <th>점수 분포</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const heights = bucketHeights(r.score_buckets);
              return (
                <tr
                  key={r.cohort_id}
                  className="sc-table-row-link"
                  onClick={(e) => {
                    if ((e.target as HTMLElement).closest("a")) return;
                    navigate(`/instructor/cohorts/${r.cohort_id}/invites`);
                  }}
                >
                  <td>
                    <Link to={`/instructor/cohorts/${r.cohort_id}/invites`}>{r.name}</Link>
                  </td>
                  <td className="sc-num">{r.invited}</td>
                  <td className="sc-num">{r.started}</td>
                  <td className="sc-num">{r.finished}</td>
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
    </>
  );
}
