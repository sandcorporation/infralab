import { useEffect, useState } from "react";
import { Link, Outlet, useOutletContext, useParams } from "react-router-dom";
import {
  ApiError,
  formatTime,
  instructor,
  joinUrl,
  type Cohort,
  type ExamInvite,
  type Participant,
} from "../api";
import { ExamInvites, ExamSettingsForm, STATUS_LABEL, examSettingsSaved } from "../components/ExamPanel";
import { ScenarioPicker } from "../components/ScenarioPicker";
import { ConfirmDialog, LinkTabs, PageHead, StatRow, type TabItem } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";

/** 기수 상세의 탭들이 나눠 쓰는 상태. 레이아웃이 한 번 받아 둔다. */
export type CohortCtx = {
  cohort: Cohort;
  setCohort: (c: Cohort | ((prev: Cohort) => Cohort)) => void;
  people: Participant[] | null;
  setPeople: (fn: (prev: Participant[]) => Participant[]) => void;
};

export const useCohort = () => useOutletContext<CohortCtx>();

/** 기수 상세의 탭 목록(하위 경로). 응시 링크는 시험 회차에만. */
export function cohortTabs(c: Pick<Cohort, "id" | "kind" | "member_count" | "open_scenario_ids">): TabItem[] {
  const base = `/instructor/cohorts/${c.id}`;
  return [
    { to: base, label: "개요", end: true },
    { to: `${base}/scenarios`, label: "시나리오", count: c.open_scenario_ids.length },
    { to: `${base}/students`, label: "학생", count: c.member_count },
    { to: `${base}/grid`, label: "진행" },
    ...(c.kind === "exam" ? [{ to: `${base}/invites`, label: "응시 링크" }] : []),
    { to: `${base}/settings`, label: "설정" },
  ];
}

/** 기수 상세 골격: 머리(이름·상태) + 탭 + 지금 탭. */
export default function InstructorCohortPage() {
  const { id = "" } = useParams();
  const cohortId = Number(id);
  const [cohort, setCohortState] = useState<Cohort | null>(null);
  const [people, setPeopleState] = useState<Participant[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setError(null);
    let cancelled = false;
    Promise.all([instructor.cohort(cohortId), instructor.participants(cohortId)])
      .then(([c, p]) => {
        if (cancelled) return;
        setCohortState(c);
        setPeopleState(p);
      })
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId]);

  useCrumbs([{ label: "기수", to: "/instructor" }, { label: cohort?.name ?? "…" }]);

  if (error && !cohort) return <p className="error">{error}</p>;
  if (!cohort || cohort.id !== cohortId) return <p className="muted">불러오는 중…</p>;
  const c = cohort;
  // 서버가 가입을 받는 조건과 같다 — 보관된 기수는 join_open 이어도 닫힌 것이다.
  const effectivelyOpen = c.join_open && !c.archived;
  const ctx: CohortCtx = {
    cohort: c,
    setCohort: (next) => setCohortState((prev) => (prev ? (typeof next === "function" ? next(prev) : next) : prev)),
    people,
    setPeople: (fn) => setPeopleState((prev) => (prev ? fn(prev) : prev)),
  };

  return (
    <>
      <PageHead
        title={c.name}
        badges={
          <>
            <span className="sc-badge sc-badge--info">{c.kind === "exam" ? "시험" : "수업"}</span>
            {c.archived && <span className="sc-badge sc-badge--neutral">보관됨</span>}
            {!effectivelyOpen && <span className="sc-badge sc-badge--neutral">가입 닫힘</span>}
          </>
        }
        sub={`만든 날 ${formatTime(c.created_at)}`}
      />
      <LinkTabs label="기수 상세" items={cohortTabs(c)} />
      <Outlet context={ctx} />
    </>
  );
}

function useCopy() {
  const [copied, setCopied] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  async function copy(key: string, text: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(key);
      setTimeout(() => setCopied((cur) => (cur === key ? null : cur)), 1500);
    } catch {
      setError("클립보드에 복사하지 못했습니다. 링크를 직접 선택해 복사하세요.");
    }
  }
  return { copied, copyError: error, copy };
}

/** 개요: 요약 타일 + 자주 쓰는 일(가입 링크 복사·응시 링크 발급) + 최근 가입. */
export function CohortOverview() {
  const { cohort: c, people } = useCohort();
  const { copied, copyError, copy } = useCopy();
  const [invites, setInvites] = useState<ExamInvite[] | null>(null);
  const effectivelyOpen = c.join_open && !c.archived;
  const base = `/instructor/cohorts/${c.id}`;

  useEffect(() => {
    if (c.kind !== "exam") return;
    let cancelled = false;
    instructor
      .examInvites(c.id)
      .then((r) => !cancelled && setInvites(r))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [c.id, c.kind]);

  const count = (s: ExamInvite["status"]) => invites?.filter((i) => i.status === s).length ?? 0;
  const recent = [...(people ?? [])].sort((a, b) => b.joined_at.localeCompare(a.joined_at)).slice(0, 5);

  return (
    <>
      <StatRow
        items={[
          { label: "학생", value: c.member_count },
          { label: "열린 시나리오", value: c.open_scenario_ids.length },
          ...(c.kind === "exam"
            ? [
                { label: "응시 링크", value: invites?.length ?? "—" },
                { label: STATUS_LABEL.in_progress, value: invites ? count("in_progress") : "—" },
                { label: STATUS_LABEL.finished, value: invites ? count("finished") : "—" },
              ]
            : [{ label: "가입", value: effectivelyOpen ? "열림" : "닫힘" }]),
        ]}
      />

      <div className="panel-grid">
        {c.kind === "exam" ? (
          <section className="sc-panel">
            <div className="sc-panel-section">
              <h2 className="sc-panel-title">응시 링크</h2>
              {examSettingsSaved(c) ? (
                <div className="row">
                  <Link className="button" to={`${base}/invites?new=1`}>
                    응시 링크 발급
                  </Link>
                  <Link to={`${base}/invites`}>전체 보기</Link>
                </div>
              ) : (
                <p className="muted">
                  시험 설정을 저장해야 응시 링크를 발급할 수 있습니다. <Link to={`${base}/settings`}>설정으로</Link>
                </p>
              )}
            </div>
          </section>
        ) : (
          <section className="sc-panel">
            <div className="sc-panel-section">
              <h2 className="sc-panel-title">가입 링크</h2>
              {effectivelyOpen ? (
                <div className="link-box">
                  <code>{joinUrl(c.join_token)}</code>
                  <button onClick={() => copy("join", joinUrl(c.join_token))}>{copied === "join" ? "복사됨" : "복사"}</button>
                </div>
              ) : (
                <p className="muted">
                  {c.archived ? "보관된 기수 — 가입 불가" : "가입 닫힘"} · <Link to={`${base}/settings`}>설정에서 열기</Link>
                </p>
              )}
              {copyError && <p className="error">{copyError}</p>}
            </div>
          </section>
        )}
        <section className="sc-panel">
          <div className="sc-panel-section">
            <h2 className="sc-panel-title">최근 가입</h2>
            {people && people.length === 0 && <p className="muted">참여자 없음</p>}
            {recent.length > 0 && (
              <ul className="list">
                {recent.map((p) => (
                  <li key={p.membership_id} className="row">
                    <span className="grow">{p.display_name || p.username}</span>
                    <span className="muted">{formatTime(p.joined_at)}</span>
                  </li>
                ))}
              </ul>
            )}
            {(people?.length ?? 0) > recent.length && <Link to={`${base}/students`}>학생 전체</Link>}
          </div>
        </section>
      </div>
    </>
  );
}

/** 시나리오: 기수에 열어 둘 시나리오 고르기. */
export function CohortScenarios() {
  const { cohort: c, setCohort } = useCohort();
  return (
    <ScenarioPicker
      cohortId={c.id}
      open={c.open_scenario_ids}
      onSaved={(ids) => setCohort((prev) => ({ ...prev, open_scenario_ids: ids }))}
    />
  );
}

/** 학생: 참여자 표 + 내보내기(확인 상자). */
export function CohortStudents() {
  const { cohort: c, setCohort, people, setPeople } = useCohort();
  const [removing, setRemoving] = useState<Participant | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function remove(p: Participant) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await instructor.removeParticipant(c.id, p.membership_id);
      setPeople((prev) => prev.filter((x) => x.membership_id !== p.membership_id));
      setCohort((prev) => ({ ...prev, member_count: prev.member_count - 1 }));
      setRemoving(null);
    } catch (err) {
      setError(`내보내기 실패: ${(err as ApiError).message}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      {error && <p className="error">{error}</p>}
      {people && people.length === 0 && <p className="muted">참여자 없음</p>}
      {people && people.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
            <thead>
              <tr>
                <th>이름</th>
                <th>계정</th>
                <th>가입 시각</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {people.map((p) => (
                <tr key={p.membership_id}>
                  <td>{p.display_name || <span className="muted">(이름 없음)</span>}</td>
                  <td className="muted">{p.username}</td>
                  <td>{formatTime(p.joined_at)}</td>
                  <td className="right">
                    <button className="link" onClick={() => setRemoving(p)}>
                      내보내기
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <ConfirmDialog
        open={removing !== null}
        title="학생 내보내기"
        confirmLabel="내보내기"
        busy={busy}
        onClose={() => setRemoving(null)}
        onConfirm={() => removing && remove(removing)}
      >
        <p>{removing ? removing.display_name || removing.username : ""} — 이 기수에서 내보냅니다.</p>
      </ConfirmDialog>
    </>
  );
}

/** 응시 링크(시험 회차만). */
export function CohortInvites() {
  const { cohort } = useCohort();
  if (cohort.kind !== "exam") return <p className="muted">시험 회차가 아닙니다.</p>;
  return <ExamInvites cohort={cohort} />;
}

/** 설정: 이름 · 시험 설정 · 가입 링크 관리 · 보관. */
export function CohortSettings() {
  const { cohort: c, setCohort } = useCohort();
  const { copied, copyError, copy } = useCopy();
  const [name, setName] = useState(c.name);
  const [pending, setPending] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<"regenerate" | "archive" | null>(null);
  const [error, setError] = useState<string | null>(null);

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
      setConfirming(null);
    }
  }

  return (
    <>
      {error && <p className="error">{error}</p>}
      <div className="panel-grid">
        <section className="sc-panel">
          <div className="sc-panel-section">
            <h2 className="sc-panel-title">이름</h2>
            <form
              className="row"
              onSubmit={(e) => {
                e.preventDefault();
                act("rename", "이름 바꾸기", async () => setCohort(await instructor.updateCohort(c.id, { name: name.trim() })));
              }}
            >
              <input className="grow" aria-label="기수 이름" value={name} onChange={(e) => setName(e.target.value)} />
              <button disabled={!name.trim() || name.trim() === c.name || pending === "rename"}>저장</button>
            </form>
          </div>
          <div className="sc-panel-section">
            <h2 className="sc-panel-title">가입 링크</h2>
            <div className="link-box">
              <code>{joinUrl(c.join_token)}</code>
              <button className="secondary" onClick={() => copy("join", joinUrl(c.join_token))}>
                {copied === "join" ? "복사됨" : "복사"}
              </button>
            </div>
            {copyError && <p className="error">{copyError}</p>}
            <div className="row">
              <button
                className="secondary"
                disabled={pending === "toggle-join" || c.archived}
                onClick={() =>
                  act("toggle-join", c.join_open ? "가입 닫기" : "가입 열기", async () =>
                    setCohort(await instructor.updateCohort(c.id, { join_open: !c.join_open })),
                  )
                }
              >
                {c.join_open ? "가입 닫기" : "가입 열기"}
              </button>
              <button className="secondary" onClick={() => setConfirming("regenerate")}>
                링크 재발급
              </button>
              {c.archived && <span className="muted">보관된 기수 — 가입 불가</span>}
            </div>
          </div>
          <div className="sc-panel-section">
            <h2 className="sc-panel-title">보관</h2>
            <div className="row">
              {c.archived ? (
                <button
                  className="secondary"
                  disabled={pending === "archive"}
                  onClick={() => act("archive", "보관 해제", async () => setCohort(await instructor.updateCohort(c.id, { archived: false })))}
                >
                  보관 해제
                </button>
              ) : (
                <button className="danger" onClick={() => setConfirming("archive")}>
                  이 기수 보관하기
                </button>
              )}
            </div>
          </div>
        </section>
        {c.kind === "exam" && (
          <section className="sc-panel">
            <div className="sc-panel-section">
              <h2 className="sc-panel-title">시험 설정</h2>
              <ExamSettingsForm cohort={c} onSaved={(next) => setCohort(next)} />
            </div>
          </section>
        )}
      </div>

      <ConfirmDialog
        open={confirming === "regenerate"}
        title="가입 링크 재발급"
        confirmLabel="재발급"
        busy={pending === "regenerate"}
        onClose={() => setConfirming(null)}
        onConfirm={() => act("regenerate", "링크 재발급", async () => setCohort(await instructor.regenerateJoinToken(c.id)))}
      >
        <p>옛 링크는 무효가 됩니다.</p>
      </ConfirmDialog>
      <ConfirmDialog
        open={confirming === "archive"}
        title="기수 보관"
        confirmLabel="보관"
        busy={pending === "archive"}
        onClose={() => setConfirming(null)}
        onConfirm={() => act("archive", "보관", async () => setCohort(await instructor.updateCohort(c.id, { archived: true })))}
      >
        <p>보관된 기수는 가입을 받지 않습니다.</p>
      </ConfirmDialog>
    </>
  );
}
