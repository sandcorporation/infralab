import { useEffect, useState } from "react";
import { Link, Navigate, useLocation, useNavigate } from "react-router-dom";
import { ApiError, formatTime, getMyCohorts, type MyCohort } from "../api";
import { useAuth } from "../auth";
import { PageHead } from "../components/ui";
import { shouldOpenPractice } from "../practice";
import { useCrumbs } from "../shell/crumbs";

export default function MyCohortsPage() {
  const { me } = useAuth();
  const location = useLocation();
  const justJoined = (location.state as { joined?: string } | null)?.joined;
  const [cohorts, setCohorts] = useState<MyCohort[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const navigate = useNavigate();
  useCrumbs([{ label: "내 기수" }]);

  useEffect(() => {
    getMyCohorts()
      .then(setCohorts)
      .catch((err: ApiError) => setError(err.message));
  }, []);

  if (cohorts && shouldOpenPractice(cohorts) && !justJoined) return <Navigate to="/practice" replace />;

  return (
    <>
      <PageHead title="내 기수" />
      {justJoined && <p className="notice">「{justJoined}」에 가입했습니다.</p>}
      {error && <p className="error">{error}</p>}
      {cohorts === null && !error && <p className="muted">불러오는 중…</p>}
      {cohorts && cohorts.length === 0 && (
        <p className="muted">
          가입한 기수가 없습니다.
          {me?.is_instructor && (
            <>
              {" "}
              <Link to="/instructor">강사 화면</Link>
            </>
          )}
        </p>
      )}
      {cohorts && cohorts.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
            <thead>
              <tr>
                <th>기수</th>
                <th>상태</th>
                <th>가입</th>
              </tr>
            </thead>
            <tbody>
              {cohorts.map((c) => (
                <tr
                  key={c.id}
                  className="sc-table-row-link"
                  onClick={(e) => {
                    if ((e.target as HTMLElement).closest("a")) return;
                    navigate(`/cohorts/${c.id}`);
                  }}
                >
                  <td>
                    <Link to={`/cohorts/${c.id}`}>{c.name}</Link>
                  </td>
                  <td>
                    {c.archived ? (
                      <span className="sc-badge sc-badge--neutral">보관됨</span>
                    ) : (
                      <span className="sc-badge sc-badge--success">진행 중</span>
                    )}
                  </td>
                  <td className="muted">{formatTime(c.joined_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
