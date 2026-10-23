// 검사별 결과 목록 — 학생의 채점 패널과 강사의 제출 드로어가 같은 규칙으로 그린다.
// ✓ 통과, ✗ 틀림, ! 판정 불가(error). 출력은 접어 두고 잘렸으면 표시한다.

export type ResultRow = {
  key: string;
  name: string;
  pass: boolean;
  output: string;
  truncated: boolean;
  error?: string;
  meta?: string; // 소요 시간, exit 코드 등 오른쪽에 작게
  hint?: string; // 실패했을 때만 보인다
  constraint?: boolean; // 「지켜야 할 것」 묶음
};

/** 검사 결과를 「해야 할 것」·「지켜야 할 것」 두 묶음으로 그린다. 제약이 없으면 묶음 제목 없이 한 목록. */
export function GroupedCheckResultList({ rows, openOutput = false }: { rows: ResultRow[]; openOutput?: boolean }) {
  const todo = rows.filter((r) => !r.constraint);
  const keep = rows.filter((r) => r.constraint);
  if (keep.length === 0) return <CheckResultList rows={todo} openOutput={openOutput} />;
  return (
    <>
      {todo.length > 0 && (
        <>
          <h3 className="group-title">해야 할 것</h3>
          <CheckResultList rows={todo} openOutput={openOutput} />
        </>
      )}
      <h3 className="group-title">지켜야 할 것</h3>
      <CheckResultList rows={keep} openOutput={openOutput} />
    </>
  );
}

export function CheckResultList({ rows, openOutput = false }: { rows: ResultRow[]; openOutput?: boolean }) {
  return (
    <ol className="checks">
      {rows.map((r) => (
        <li key={r.key} className={r.pass ? "pass" : r.error ? "unknown" : "fail"}>
          <div className="row">
            <span className="mark">{r.pass ? "✓" : r.error ? "!" : "✗"}</span>
            <span>{r.name}</span>
            {r.meta && <span className="muted small">{r.meta}</span>}
          </div>
          {r.error && <div className="error">{r.error}</div>}
          {!r.pass && r.hint && (
            <div className="hint">
              <code>{r.hint}</code>
            </div>
          )}
          {r.output && (
            <details open={openOutput}>
              <summary>출력{r.truncated ? " (잘림)" : ""}</summary>
              <pre>
                <code>{r.output}</code>
              </pre>
            </details>
          )}
        </li>
      ))}
    </ol>
  );
}
