import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { ApiError, formatTime, instructor, type Cohort } from "../api";

export default function InstructorCohortsPage() {
  const [cohorts, setCohorts] = useState<Cohort[] | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  function reload() {
    instructor
      .cohorts()
      .then(setCohorts)
      .catch((err: ApiError) => setError(err.message));
  }
  useEffect(reload, []);

  async function create(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await instructor.createCohort(name.trim());
      setName("");
      reload();
    } catch (err) {
      setError((err as ApiError).message);
    } finally {
      setBusy(false);
    }
  }

  const active = cohorts?.filter((c) => !c.archived) ?? [];
  const archived = cohorts?.filter((c) => c.archived) ?? [];

  return (
    <section>
      <h1>기수</h1>
      <form onSubmit={create} className="row card">
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="새 기수 이름, 예: 인프라 3기" required />
        <button type="submit" disabled={busy || !name.trim()}>
          만들기
        </button>
      </form>
      {error && <p className="error">{error}</p>}
      <CohortList cohorts={active} />
      {archived.length > 0 && (
        <>
          <h2 className="muted">보관된 기수</h2>
          <CohortList cohorts={archived} />
        </>
      )}
    </section>
  );
}

function CohortList({ cohorts }: { cohorts: Cohort[] }) {
  if (cohorts.length === 0) return <p className="muted">기수가 없습니다.</p>;
  return (
    <ul className="list">
      {cohorts.map((c) => (
        <li key={c.id} className="card">
          <div className="row">
            <Link to={`/instructor/cohorts/${c.id}`}>
              <strong>{c.name}</strong>
            </Link>
            <span className="muted">학생 {c.member_count}명</span>
            {!c.join_open && <span className="tag">가입 닫힘</span>}
            {c.archived && <span className="tag">보관됨</span>}
          </div>
          <div className="muted">만든 날 {formatTime(c.created_at)}</div>
        </li>
      ))}
    </ul>
  );
}
