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
  // 되돌리기 어려운 동작은 두 번 누르게 한다(브라우저 confirm 은 쓰지 않는다). 값은 동작 키다.
  const [confirming, setConfirming] = useState<string | null>(null);
  // 진행 중인 동작 키. 응답이 오기 전 같은 버튼을 다시 눌러 같은 값을 두 번 보내지 않게 한다.
  const [pending, setPending] = useState<string | null>(null);

  useEffect(() => {
    // 기수가 바뀌면 이전 기수의 화면 상태(확인·이름 편집·오류)는 버린다.
    setConfirming(null);
    setRenaming(null);
    setError(null);
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

  async function act(key: string, label: string, fn: () => Promise<void>) {
    if (pending) return;
    setPending(key);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(`${label} 실패: ${(err as ApiError).message}`);
    } finally {
      setPending(null);
      // 자기 확인 상태만 닫는다 — 다른 행의 「내보내기 확정」은 남는다.
      setConfirming((cur) => (cur === key ? null : cur));
    }
  }

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

  if (error && !cohort) return <p className="error">{error}</p>;
  if (!cohort) return <p className="muted">불러오는 중…</p>;
  const c = cohort;
  // 서버가 가입을 받는 조건과 같다 — 보관된 기수는 join_open 이어도 닫힌 것이다.
  const effectivelyOpen = c.join_open && !c.archived;
  const busy = (key: string) => pending === key;

  return (
    <section>
      <p>
        <Link to="/instructor">← 기수 목록</Link>
      </p>
      <div className="row">
        {renaming === null ? (
          <>
            <h1>{c.name}</h1>
            <button className="link" onClick={() => setRenaming(c.name)}>
              이름 바꾸기
            </button>
          </>
        ) : (
          <>
            <input value={renaming} onChange={(e) => setRenaming(e.target.value)} autoFocus />
            <button
              disabled={!renaming.trim() || busy("rename")}
              onClick={() =>
                act("rename", "이름 바꾸기", async () => {
                  setCohort(await instructor.updateCohort(c.id, { name: renaming.trim() }));
                  setRenaming(null);
                })
              }
            >
              저장
            </button>
            <button className="link" onClick={() => setRenaming(null)}>
              취소
            </button>
          </>
        )}
        {c.archived && <span className="tag">보관됨</span>}
        {!effectivelyOpen && <span className="tag">가입 닫힘</span>}
      </div>
      {error && <p className="error">{error}</p>}

      <section className="card">
        <h2>가입 링크</h2>
        <div className="row">
          <code className="grow">{joinUrl(c.join_token)}</code>
          <button onClick={copyLink}>{copied ? "복사됨" : "복사"}</button>
        </div>
        <div className="row actions">
          <button
            className="secondary"
            disabled={busy("toggle-join") || c.archived}
            onClick={() =>
              act("toggle-join", c.join_open ? "가입 닫기" : "가입 열기", async () => {
                setCohort(await instructor.updateCohort(c.id, { join_open: !c.join_open }));
              })
            }
          >
            {c.join_open ? "가입 닫기" : "가입 열기"}
          </button>
          {confirming === "regenerate" ? (
            <>
              <span className="muted">옛 링크는 무효가 됩니다.</span>
              <button
                className="danger"
                disabled={busy("regenerate")}
                onClick={() =>
                  act("regenerate", "링크 재발급", async () => {
                    setCohort(await instructor.regenerateJoinToken(c.id));
                  })
                }
              >
                재발급 확정
              </button>
              <button className="link" onClick={() => setConfirming(null)}>
                취소
              </button>
            </>
          ) : (
            <button className="secondary" onClick={() => setConfirming("regenerate")}>
              링크 재발급
            </button>
          )}
        </div>
        {!effectivelyOpen && <p className="muted">{c.archived ? "보관된 기수 — 가입 불가" : "가입 닫힘"}</p>}
      </section>

      <section className="card">
        <h2>학생 {people?.length ?? 0}명</h2>
        {people && people.length === 0 && <p className="muted">참여자 없음</p>}
        {people && people.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>이름</th>
                <th>계정</th>
                <th>가입 시각</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {people.map((p) => {
                const key = `remove:${p.membership_id}`;
                return (
                  <tr key={p.membership_id}>
                    <td>{p.display_name || <span className="muted">(이름 없음)</span>}</td>
                    <td className="muted">{p.username}</td>
                    <td>{formatTime(p.joined_at)}</td>
                    <td className="right">
                      {confirming === key ? (
                        <>
                          <button
                            className="danger"
                            disabled={busy(key)}
                            onClick={() =>
                              act(key, "내보내기", async () => {
                                await instructor.removeParticipant(c.id, p.membership_id);
                                setPeople((prev) => prev?.filter((x) => x.membership_id !== p.membership_id) ?? null);
                                setCohort((prev) => (prev ? { ...prev, member_count: prev.member_count - 1 } : prev));
                              })
                            }
                          >
                            내보내기 확정
                          </button>{" "}
                          <button className="link" onClick={() => setConfirming(null)}>
                            취소
                          </button>
                        </>
                      ) : (
                        <button className="link" onClick={() => setConfirming(key)}>
                          내보내기
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>

      <section className="card">
        <h2>보관</h2>
        <button
          className="secondary"
          disabled={busy("archive")}
          onClick={() =>
            act("archive", c.archived ? "보관 해제" : "보관", async () => {
              setCohort(await instructor.updateCohort(c.id, { archived: !c.archived }));
            })
          }
        >
          {c.archived ? "보관 해제" : "이 기수 보관하기"}
        </button>
      </section>
    </section>
  );
}
