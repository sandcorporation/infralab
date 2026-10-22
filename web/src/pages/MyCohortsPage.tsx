import { useEffect, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { ApiError, formatTime, getMyCohorts, type MyCohort } from "../api";
import { useAuth } from "../auth";

export default function MyCohortsPage() {
  const { me } = useAuth();
  const location = useLocation();
  const justJoined = (location.state as { joined?: string } | null)?.joined;
  const [cohorts, setCohorts] = useState<MyCohort[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getMyCohorts()
      .then(setCohorts)
      .catch((err: ApiError) => setError(err.message));
  }, []);

  return (
    <section>
      <h1>내 기수</h1>
      {justJoined && <p className="notice">「{justJoined}」에 가입했습니다.</p>}
      {error && <p className="error">{error}</p>}
      {cohorts && cohorts.length === 0 && (
        <p className="muted">
          아직 들어간 기수가 없습니다. 강사가 준 가입 링크를 열면 들어갑니다.
          {me?.is_instructor && (
            <>
              {" "}
              강사라면 <Link to="/instructor">강사 화면</Link>에서 기수를 만듭니다.
            </>
          )}
        </p>
      )}
      <ul className="list">
        {cohorts?.map((c) => (
          <li key={c.id} className="card">
            <div className="row">
              <strong>{c.name}</strong>
              {c.archived && <span className="tag">보관됨</span>}
            </div>
            <div className="muted">가입 {formatTime(c.joined_at)}</div>
          </li>
        ))}
      </ul>
    </section>
  );
}
