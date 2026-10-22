import { useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ApiError, formatTime, instructor, parseId, type Grid, type GridRow, type Submission, type SubmissionSummary } from "../api";
import { CheckResultList } from "../components/CheckResultList";

const POLL_MS = 10000;

type Selected = { membershipId: number; scenarioId: string };

/** 버전 문자열을 숫자 자리 단위로 비교한다 — "0.10.0" 이 "0.9.0" 보다 크다. */
const compareVersions = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true });

// 기수 × 시나리오 격자. 수업 중 저절로 갱신된다(폴링, 탭이 숨겨지면 멈춘다). 칸을 누르면 그 학생의 최신 제출
// 증거와 이력이 아래에 열린다.
export default function InstructorGridPage() {
  const { id } = useParams();
  const cohortId = parseId(id);
  const [grid, setGrid] = useState<Grid | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);
  const [selected, setSelected] = useState<Selected | null>(null);

  useEffect(() => {
    if (cohortId === null) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    async function tick() {
      if (cancelled) return;
      if (document.hidden) {
        // 보이지 않는 탭은 서버를 때리지 않는다 — 다시 보일 때 visibilitychange 가 바로 한 번 돌린다.
        timer = undefined;
        return;
      }
      try {
        const g = await instructor.grid(cohortId!);
        if (cancelled) return;
        setGrid(g);
        setUpdatedAt(new Date());
        setError(null);
      } catch (err) {
        if (!cancelled) setError((err as ApiError).message);
      }
      if (!cancelled) timer = setTimeout(tick, POLL_MS);
    }
    const onVisible = () => {
      if (!document.hidden && timer === undefined) tick();
    };
    document.addEventListener("visibilitychange", onVisible);
    tick();
    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", onVisible);
      if (timer) clearTimeout(timer);
    };
  }, [cohortId]);

  if (cohortId === null) return <p className="error">없는 기수입니다.</p>;
  if (error && !grid) return <p className="error">{error}</p>;
  if (!grid) return <p className="muted">불러오는 중…</p>;

  // 가장 최근 버전보다 낮은 에이전트는 표시한다 — 「오래된 에이전트」를 찾는 자리.
  const versions = grid.rows.flatMap((r) => Object.values(r.cells).flatMap((c) => (c ? [c.agent_version] : [])));
  const newest = versions.sort(compareVersions).at(-1) ?? "";
  const selectedRow = selected ? grid.rows.find((r) => r.membership_id === selected.membershipId) : undefined;
  const selectedCell = selectedRow && selected ? selectedRow.cells[selected.scenarioId] : null;

  return (
    <section>
      <p>
        <Link to={`/instructor/cohorts/${cohortId}`}>← 기수 관리</Link>
      </p>
      <div className="row">
        <h1>진행 격자</h1>
        <span className="muted">
          {updatedAt ? `${formatTime(updatedAt.toISOString())} 갱신` : ""} · {POLL_MS / 1000}초마다
        </span>
        {error && <span className="error">{error}</span>}
      </div>
      {grid.scenarios.length === 0 && <p className="muted">열린 시나리오가 없습니다.</p>}
      {grid.rows.length === 0 && <p className="muted">참여자가 없습니다.</p>}
      {grid.scenarios.length > 0 && grid.rows.length > 0 && (
        <div className="card grid-wrap">
          <table className="grid">
            <thead>
              <tr>
                <th>학생</th>
                {grid.scenarios.map((s) => (
                  <th key={s.id}>
                    {s.title} <span className="muted">/{s.total}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {grid.rows.map((row) => (
                <tr key={row.membership_id}>
                  <td>
                    {row.display_name || <span className="muted">(이름 없음)</span>}
                    <div className="muted small">{row.username}</div>
                  </td>
                  {grid.scenarios.map((s) => {
                    const cell = row.cells[s.id];
                    const active = selected?.membershipId === row.membership_id && selected.scenarioId === s.id;
                    return (
                      <td key={s.id} className={active ? "active" : ""}>
                        {cell ? (
                          <button className="cell" onClick={() => setSelected({ membershipId: row.membership_id, scenarioId: s.id })}>
                            <span className={cell.passed === cell.total ? "score done" : "score"}>
                              {cell.passed}/{cell.total}
                            </span>
                            <span className="small muted">{formatTime(cell.submitted_at)}</span>
                            <span className={`small ${compareVersions(cell.agent_version, newest) < 0 ? "stale" : "muted"}`}>
                              v{cell.agent_version || "?"}
                            </span>
                          </button>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {selected && selectedRow && (
        <SubmissionDrawer
          // 새 제출이 들어오면(최신 제출 id 변화) 드로어도 다시 읽는다.
          key={`${selected.membershipId}:${selected.scenarioId}:${selectedCell?.submission_id ?? 0}`}
          cohortId={cohortId}
          row={selectedRow}
          scenarioId={selected.scenarioId}
          scenarioTitle={grid.scenarios.find((s) => s.id === selected.scenarioId)?.title ?? selected.scenarioId}
          onClose={() => setSelected(null)}
        />
      )}
    </section>
  );
}

function SubmissionDrawer({
  cohortId,
  row,
  scenarioId,
  scenarioTitle,
  onClose,
}: {
  cohortId: number;
  row: GridRow;
  scenarioId: string;
  scenarioTitle: string;
  onClose: () => void;
}) {
  const [history, setHistory] = useState<SubmissionSummary[] | null>(null);
  const [current, setCurrent] = useState<Submission | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 마지막으로 고른 제출만 화면에 남는다 — 늦게 도착한 옛 요청이 덮어쓰지 않게.
  const wanted = useRef<number | null>(null);

  async function show(id: number) {
    wanted.current = id;
    try {
      const sub = await instructor.submission(id);
      if (wanted.current === id) setCurrent(sub);
    } catch (err) {
      if (wanted.current === id) setError((err as ApiError).message);
    }
  }

  useEffect(() => {
    let cancelled = false;
    instructor
      .history(cohortId, row.membership_id, scenarioId)
      .then((h) => {
        if (cancelled) return;
        setHistory(h);
        if (h.length > 0) show(h[0].id);
      })
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
      wanted.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cohortId, row.membership_id, scenarioId]);

  return (
    <section className="card drawer">
      <div className="row">
        <h2>
          {row.display_name || row.username} · {scenarioTitle}
        </h2>
        <button className="link" onClick={onClose}>
          닫기
        </button>
      </div>
      {error && <p className="error">{error}</p>}
      <div className="drawer-grid">
        <div>
          <h3>이력</h3>
          {history && history.length === 0 && <p className="muted">제출 없음</p>}
          <ul className="list plain">
            {history?.map((h) => (
              <li key={h.id}>
                <button className={`link ${current?.id === h.id ? "current" : ""}`} onClick={() => show(h.id)}>
                  {formatTime(h.submitted_at)} · {h.passed}/{h.total} · v{h.agent_version || "?"}
                </button>
              </li>
            ))}
          </ul>
        </div>
        <div>
          {current && (
            <>
              <h3>
                {formatTime(current.submitted_at)} · {current.passed}/{current.total}
              </h3>
              <CheckResultList
                openOutput
                rows={current.results.map((r) => ({
                  key: r.check_id,
                  name: r.name,
                  pass: r.pass,
                  output: r.output,
                  truncated: r.truncated,
                  error: r.error || undefined,
                  meta: `exit ${r.exit_code}`,
                }))}
              />
            </>
          )}
        </div>
      </div>
    </section>
  );
}
