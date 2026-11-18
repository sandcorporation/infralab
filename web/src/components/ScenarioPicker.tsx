import { useEffect, useState } from "react";
import { ApiError, instructor, type ScenarioSummary } from "../api";

// 강사가 기수에 열어 둘 시나리오를 고른다. 저장 순서는 카탈로그 순서다.
export function ScenarioPicker({
  cohortId,
  open,
  onSaved,
}: {
  cohortId: number;
  open: string[];
  onSaved: (ids: string[]) => void;
}) {
  const [catalog, setCatalog] = useState<ScenarioSummary[] | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set(open));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    instructor
      .scenarios()
      .then((c) => !cancelled && setCatalog(c))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, []);

  // 서버값이 실제로 바뀌었을 때만 선택을 되돌린다 — 같은 화면의 다른 동작(가입 토글 등)이 기수를 다시 받아
  // 배열 참조만 바뀐 경우에 저장 전 체크가 사라지면 안 된다.
  const openKey = open.join(",");
  useEffect(() => setSelected(new Set(openKey ? openKey.split(",") : [])), [openKey]);

  const dirty = catalog !== null && (selected.size !== open.length || open.some((id) => !selected.has(id)));

  async function save() {
    if (!catalog) return;
    setBusy(true);
    setError(null);
    try {
      const ids = catalog.filter((s) => selected.has(s.id)).map((s) => s.id);
      onSaved(await instructor.setOpenScenarios(cohortId, ids));
    } catch (err) {
      setError((err as ApiError).message);
    } finally {
      setBusy(false);
    }
  }

  if (error && !catalog) return <p className="error">{error}</p>;
  if (!catalog) return <p className="muted">불러오는 중…</p>;

  return (
    <>
      {catalog.length === 0 && <p className="muted">시나리오가 없습니다.</p>}
      <ul className="list plain">
        {catalog.map((s) => (
          <li key={s.id}>
            <label className="check">
              <input
                type="checkbox"
                checked={selected.has(s.id)}
                onChange={(e) => {
                  const next = new Set(selected);
                  if (e.target.checked) next.add(s.id);
                  else next.delete(s.id);
                  setSelected(next);
                }}
              />
              <span>
                <strong>{s.title}</strong> <span className="muted">{s.id}</span>
                <RequiresTags requires={s.requires} /> <span className="muted">검사 {s.total}</span>
              </span>
            </label>
          </li>
        ))}
      </ul>
      {error && <p className="error">{error}</p>}
      <button onClick={save} disabled={!dirty || busy}>
        {busy ? "저장 중…" : "저장"}
      </button>
    </>
  );
}

export function RequiresTags({ requires }: { requires: ScenarioSummary["requires"] }) {
  return (
    <>
      {requires.floci && <span className="sc-badge sc-badge--neutral">Floci</span>}{" "}
      {requires.kind && (
        <span className="sc-badge sc-badge--neutral">
          kind {requires.kind.control_planes}cp+{requires.kind.workers}w
        </span>
      )}
    </>
  );
}
