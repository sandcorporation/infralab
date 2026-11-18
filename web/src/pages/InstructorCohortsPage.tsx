import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../auth";
import { ApiError, formatTime, instructor, type Cohort, type CohortKind } from "../api";
import { KIND_LABEL, loadSelectedOrg, pickOrg, saveSelectedOrg } from "../orgSelection";

export default function InstructorCohortsPage() {
  const { me } = useAuth();
  const orgs = me?.orgs ?? [];
  const [orgId, setOrgId] = useState<number | null>(() => pickOrg(orgs, loadSelectedOrg())?.id ?? null);
  const [kind, setKind] = useState<CohortKind>("class");
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
      if (orgId === null) return;
      await instructor.createCohort(name.trim(), orgId, kind);
      setName("");
      reload();
    } catch (err) {
      setError((err as ApiError).message);
    } finally {
      setBusy(false);
    }
  }

  function chooseOrg(id: number) {
    setOrgId(id);
    saveSelectedOrg(id);
  }

  const inOrg = cohorts?.filter((c) => c.org_id === orgId) ?? [];
  const active = inOrg.filter((c) => !c.archived);
  const archived = inOrg.filter((c) => c.archived);
  const org = orgs.find((o) => o.id === orgId);

  return (
    <section>
      {org &&
        (orgs.length > 1 ? (
          <select aria-label="조직" value={org.id} onChange={(e) => chooseOrg(Number(e.target.value))}>
            {orgs.map((o) => (
              <option key={o.id} value={o.id}>
                {o.name}
              </option>
            ))}
          </select>
        ) : (
          <p className="muted">{org.name}</p>
        ))}
      <h1>{KIND_LABEL.class}</h1>
      <form onSubmit={create} className="row card">
        <div role="radiogroup" aria-label="종류" className="row">
          {(["class", "exam"] as const).map((k) => (
            <button
              key={k}
              type="button"
              role="radio"
              aria-checked={kind === k}
              className={kind === k ? "" : "secondary"}
              onClick={() => setKind(k)}
            >
              {k === "class" ? "수업" : "시험"}
            </button>
          ))}
        </div>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={kind === "exam" ? "새 시험 회차 이름, 예: 신입 진단 1회차" : "새 기수 이름, 예: 인프라 3기"}
          required
        />
        <button type="submit" disabled={busy || !name.trim() || orgId === null}>
          만들기
        </button>
      </form>
      {error && <p className="error">{error}</p>}
      <CohortList cohorts={active} />
      {archived.length > 0 && (
        <>
          <h2 className="muted">보관된 묶음</h2>
          <CohortList cohorts={archived} />
        </>
      )}
    </section>
  );
}

function CohortList({ cohorts }: { cohorts: Cohort[] }) {
  if (cohorts.length === 0) return <p className="muted">묶음이 없습니다.</p>;
  return (
    <ul className="list">
      {cohorts.map((c) => (
        <li key={c.id} className="card">
          <div className="row">
            <Link to={`/instructor/cohorts/${c.id}`}>
              <strong>{c.name}</strong>
            </Link>
            <span className="muted">학생 {c.member_count}명</span>
            {!c.join_open && <span className="sc-badge sc-badge--neutral">가입 닫힘</span>}
            {c.kind === "exam" && <span className="sc-badge sc-badge--neutral">{KIND_LABEL.exam}</span>}
            {c.archived && <span className="sc-badge sc-badge--neutral">보관됨</span>}
          </div>
          <div className="muted">만든 날 {formatTime(c.created_at)}</div>
        </li>
      ))}
    </ul>
  );
}
