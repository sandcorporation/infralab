import { useEffect, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { ApiError, formatTime, instructor, type Cohort, type CohortKind } from "../api";
import { KIND_LABEL } from "../orgSelection";
import { OrgSelect, useSelectedOrg } from "../components/OrgSelect";
import { Modal, PageHead } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";
import { IconPlus, IconSearch } from "../shell/icons";

type Filter = "active" | "class" | "exam" | "archived";
const FILTERS: { key: Filter; label: string }[] = [
  { key: "active", label: "진행 중" },
  { key: "class", label: "수업" },
  { key: "exam", label: "시험" },
  { key: "archived", label: "보관됨" },
];

/** 목록 거름: 보관은 「보관됨」에서만, 종류 거름은 보관 안 된 것 중에서. 이름 찾기는 대소문자 무시. */
export function filterCohorts(cohorts: Cohort[], orgId: number | null, filter: Filter, query: string): Cohort[] {
  const q = query.trim().toLowerCase();
  return cohorts.filter(
    (c) =>
      c.org_id === orgId &&
      (filter === "archived" ? c.archived : !c.archived && (filter === "active" || c.kind === filter)) &&
      (!q || c.name.toLowerCase().includes(q)),
  );
}

// 기수 목록: 표 + 거름 칩 + 찾기, 만들기는 상자(?new=1).
export default function InstructorCohortsPage() {
  const selected = useSelectedOrg();
  const orgId = selected.org?.id ?? null;
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const creating = params.get("new") === "1";
  const filter = (FILTERS.find((f) => f.key === params.get("filter"))?.key ?? "active") as Filter;
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<CohortKind>("class");
  const [cohorts, setCohorts] = useState<Cohort[] | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useCrumbs([{ label: "기수" }]);

  useEffect(() => {
    instructor
      .cohorts()
      .then(setCohorts)
      .catch((err: ApiError) => setError(err.message));
  }, []);

  function setParam(key: string, value: string | null) {
    const next = new URLSearchParams(params);
    if (value === null) next.delete(key);
    else next.set(key, value);
    setParams(next, { replace: true });
  }

  async function create(e: FormEvent) {
    e.preventDefault();
    if (orgId === null || !name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const c = await instructor.createCohort(name.trim(), orgId, kind);
      navigate(`/instructor/cohorts/${c.id}`);
    } catch (err) {
      setError((err as ApiError).message);
    } finally {
      setBusy(false);
    }
  }

  const rows = cohorts ? filterCohorts(cohorts, orgId, filter, query) : [];
  const count = (f: Filter) => (cohorts ? filterCohorts(cohorts, orgId, f, "").length : 0);

  return (
    <>
      <PageHead
        title={KIND_LABEL.class}
        sub={<OrgSelect {...selected} />}
        actions={
          <button disabled={orgId === null} onClick={() => setParam("new", "1")}>
            <IconPlus /> 새 기수
          </button>
        }
      />
      <div className="sc-toolbar">
        <div className="sc-toolbar-chips" role="group" aria-label="거름">
          {FILTERS.map((f) => (
            <button
              key={f.key}
              type="button"
              className="sc-chip"
              aria-pressed={filter === f.key}
              onClick={() => setParam("filter", f.key === "active" ? null : f.key)}
            >
              {f.label}
              <span className="sc-chip-count">{count(f.key)}</span>
            </button>
          ))}
        </div>
        <label className="sc-toolbar-search">
          <IconSearch />
          <span className="sc-visually-hidden">이름 찾기</span>
          <input type="search" placeholder="이름 찾기" value={query} onChange={(e) => setQuery(e.target.value)} />
        </label>
      </div>
      {error && !creating && <p className="error">{error}</p>}
      {cohorts === null && !error && <p className="muted">불러오는 중…</p>}
      {cohorts && rows.length === 0 && <p className="muted">묶음이 없습니다.</p>}
      {rows.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
            <thead>
              <tr>
                <th>이름</th>
                <th>종류</th>
                <th className="sc-num">학생</th>
                <th className="sc-num">열린 시나리오</th>
                <th>가입</th>
                <th>만든 날</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((c) => (
                <tr
                  key={c.id}
                  className="sc-table-row-link"
                  onClick={(e) => {
                    if ((e.target as HTMLElement).closest("a")) return;
                    navigate(`/instructor/cohorts/${c.id}`);
                  }}
                >
                  <td>
                    <Link to={`/instructor/cohorts/${c.id}`}>{c.name}</Link>
                  </td>
                  <td>
                    <span className="sc-badge sc-badge--info">{c.kind === "exam" ? "시험" : "수업"}</span>
                  </td>
                  <td className="sc-num">{c.member_count}</td>
                  <td className="sc-num">{c.open_scenario_ids.length}</td>
                  <td>
                    {c.archived ? (
                      <span className="sc-badge sc-badge--neutral">보관됨</span>
                    ) : c.join_open ? (
                      <span className="sc-badge sc-badge--success">열림</span>
                    ) : (
                      <span className="sc-badge sc-badge--neutral">닫힘</span>
                    )}
                  </td>
                  <td>{formatTime(c.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        open={creating}
        title="새 기수"
        onClose={() => setParam("new", null)}
        foot={
          <>
            <button type="button" className="secondary" onClick={() => setParam("new", null)}>
              취소
            </button>
            <button type="submit" form="create-cohort" disabled={busy || !name.trim() || orgId === null}>
              만들기
            </button>
          </>
        }
      >
        <form id="create-cohort" onSubmit={create}>
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
          <label>
            이름
            <input
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder={kind === "exam" ? "예: 신입 진단 1회차" : "예: 인프라 3기"}
              required
            />
          </label>
          {error && <p className="error">{error}</p>}
        </form>
      </Modal>
    </>
  );
}
