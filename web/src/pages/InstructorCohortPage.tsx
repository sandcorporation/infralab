import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ApiError, formatTime, instructor, joinUrl, type Cohort, type Participant } from "../api";

export default function InstructorCohortPage() {
  const { id = "" } = useParams();
  const cohortId = Number(id);
  const [cohort, setCohort] = useState<Cohort | null>(null);
  const [people, setPeople] = useState<Participant[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [renaming, setRenaming] = useState<string | null>(null);

  useEffect(() => {
    // 기수를 빠르게 바꿨을 때 늦게 도착한 옛 기수 응답이 새 화면을 덮지 않게 한다.
    let cancelled = false;
    Promise.all([instructor.cohort(cohortId), instructor.participants(cohortId)])
      .then(([c, p]) => {
        if (cancelled) return;
        setCohort(c);
        setPeople(p);
      })
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId]);

  async function copyLink() {
    if (!cohort) return;
    try {
      await navigator.clipboard.writeText(joinUrl(cohort.join_token));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setError("클립보드에 복사하지 못했습니다. 링크를 직접 선택해 복사하세요.");
    }
  }

  async function rename() {
    if (!cohort || renaming === null) return;
    try {
      setCohort(await instructor.renameCohort(cohort.id, renaming.trim()));
      setRenaming(null);
    } catch (err) {
      setError((err as ApiError).message);
    }
  }

  if (error && !cohort) return <p className="error">{error}</p>;
  if (!cohort) return <p className="muted">불러오는 중…</p>;

  return (
    <section>
      <p>
        <Link to="/instructor">← 기수 목록</Link>
      </p>
      <div className="row">
        {renaming === null ? (
          <>
            <h1>{cohort.name}</h1>
            <button className="link" onClick={() => setRenaming(cohort.name)}>
              이름 바꾸기
            </button>
          </>
        ) : (
          <>
            <input value={renaming} onChange={(e) => setRenaming(e.target.value)} autoFocus />
            <button onClick={rename} disabled={!renaming.trim()}>
              저장
            </button>
            <button className="link" onClick={() => setRenaming(null)}>
              취소
            </button>
          </>
        )}
        {cohort.archived && <span className="tag">보관됨</span>}
      </div>
      {error && <p className="error">{error}</p>}

      <section className="card">
        <h2>가입 링크</h2>
        <p className="muted">수업 첫날 이 링크 하나만 뿌리면 학생이 카카오로 로그인해 스스로 들어옵니다.</p>
        <div className="row">
          <code className="grow">{joinUrl(cohort.join_token)}</code>
          <button onClick={copyLink}>{copied ? "복사됨" : "복사"}</button>
        </div>
        {!cohort.join_open && <p className="error">지금은 가입이 닫혀 있습니다.</p>}
      </section>

      <section className="card">
        <h2>학생 {people?.length ?? 0}명</h2>
        {people && people.length === 0 && <p className="muted">아직 아무도 들어오지 않았습니다.</p>}
        {people && people.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>이름</th>
                <th>계정</th>
                <th>가입 시각</th>
              </tr>
            </thead>
            <tbody>
              {people.map((p) => (
                <tr key={p.membership_id}>
                  <td>{p.display_name || <span className="muted">(이름 없음)</span>}</td>
                  <td className="muted">{p.username}</td>
                  <td>{formatTime(p.joined_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </section>
  );
}
