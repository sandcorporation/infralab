import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  ApiError,
  examInviteUrl,
  formatTime,
  instructor,
  type Cohort,
  type ExamEvent,
  type ExamInvite,
  type ExamSettings,
  type ExamTool,
} from "../api";

const SIGNAL_LABEL: Record<string, string> = {
  tab_hidden: "탭 이탈",
  focus_lost: "포커스 잃음",
  paste: "붙여넣기",
  ai_outside_proxy: "프록시 밖 AI 사용",
};

const TOOLS: { key: ExamTool; label: string }[] = [
  { key: "claude_code", label: "Claude Code" },
  { key: "codex", label: "Codex" },
  { key: "local_llm", label: "로컬 LLM" },
];
const STATUS_LABEL: Record<ExamInvite["status"], string> = {
  invited: "초대됨",
  in_progress: "응시 중",
  finished: "끝남",
  revoked: "회수됨",
};
const DEFAULTS: ExamSettings = {
  time_limit_minutes: 90,
  tools: [],
  models: {},
  proctoring: false,
  hidden_checks: false,
  ai_token_limit: 0,
};

function initial(raw: Cohort["exam_settings"]): ExamSettings {
  return { ...DEFAULTS, ...(raw as Partial<ExamSettings>) };
}

/** 시험 회차의 설정 폼과 응시 링크 목록(발급·복사·회수). */
export function ExamPanel({ cohort, onSaved }: { cohort: Cohort; onSaved: (c: Cohort) => void }) {
  const saved = Object.keys(cohort.exam_settings).length > 0;
  const [form, setForm] = useState<ExamSettings>(() => initial(cohort.exam_settings));
  const [invites, setInvites] = useState<ExamInvite[] | null>(null);
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState<number | null>(null);
  const [eventsOf, setEventsOf] = useState<{ id: number; events: ExamEvent[] } | null>(null);

  useEffect(() => {
    let cancelled = false;
    instructor
      .examInvites(cohort.id)
      .then((r) => !cancelled && setInvites(r))
      .catch((e: ApiError) => !cancelled && setError(e.message));
    return () => {
      cancelled = true;
    };
  }, [cohort.id]);

  async function run(fn: () => Promise<void>, what: string) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(`${what} 실패: ${(e as ApiError).message}`);
    } finally {
      setBusy(false);
    }
  }

  function toggleTool(tool: ExamTool) {
    setForm((f) => ({
      ...f,
      tools: f.tools.includes(tool) ? f.tools.filter((t) => t !== tool) : [...f.tools, tool],
    }));
  }

  async function copy(i: ExamInvite) {
    try {
      await navigator.clipboard.writeText(examInviteUrl(i.token));
      setCopied(i.id);
      setTimeout(() => setCopied((cur) => (cur === i.id ? null : cur)), 1500);
    } catch {
      setError("클립보드에 복사하지 못했습니다. 링크를 직접 선택해 복사하세요.");
    }
  }

  return (
    <>
      <section className="card">
        <h2>시험 설정</h2>
        <div className="row">
          <label>
            시간 제한(분){" "}
            <input
              type="number"
              min={1}
              max={600}
              value={form.time_limit_minutes}
              onChange={(e) => setForm({ ...form, time_limit_minutes: Number(e.target.value) })}
            />
          </label>
          <label>
            임시 토큰 한도(토큰){" "}
            <input
              type="number"
              min={0}
              value={form.ai_token_limit}
              onChange={(e) => setForm({ ...form, ai_token_limit: Number(e.target.value) })}
            />
          </label>
        </div>
        <fieldset>
          <legend>허용 도구 (비워 두면 AI 없는 시험)</legend>
          {TOOLS.map((t) => (
            <div className="row" key={t.key}>
              <label>
                <input type="checkbox" checked={form.tools.includes(t.key)} onChange={() => toggleTool(t.key)} />{" "}
                {t.label}
              </label>
              {(t.key === "claude_code" || t.key === "codex") && form.tools.includes(t.key) && (
                <input
                  placeholder="고정 모델"
                  aria-label={`${t.label} 모델`}
                  value={form.models[t.key] ?? ""}
                  onChange={(e) => setForm({ ...form, models: { ...form.models, [t.key]: e.target.value } })}
                />
              )}
            </div>
          ))}
        </fieldset>
        <div className="row">
          <label>
            <input
              type="checkbox"
              checked={form.proctoring}
              onChange={(e) => setForm({ ...form, proctoring: e.target.checked })}
            />{" "}
            감독
          </label>
          <label>
            <input
              type="checkbox"
              checked={form.hidden_checks}
              onChange={(e) => setForm({ ...form, hidden_checks: e.target.checked })}
            />{" "}
            숨은 검사 사용
          </label>
        </div>
        <div className="row actions">
          <button
            disabled={busy}
            onClick={() => run(async () => onSaved(await instructor.setExamSettings(cohort.id, form)), "설정 저장")}
          >
            설정 저장
          </button>
          {!saved && <span className="muted">설정을 저장해야 응시 링크를 발급할 수 있습니다.</span>}
        </div>
        {error && <p className="error">{error}</p>}
      </section>

      <section className="card">
        <h2>응시 링크 {invites?.length ?? 0}</h2>
        <div className="row">
          <input
            className="grow"
            placeholder="지원자 표시 이름(메모)"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
          <button
            disabled={busy || !saved || !label.trim()}
            onClick={() =>
              run(async () => {
                const created = await instructor.createExamInvite(cohort.id, label.trim());
                setInvites((prev) => [...(prev ?? []), created]);
                setLabel("");
              }, "링크 발급")
            }
          >
            링크 발급
          </button>
        </div>
        {invites && invites.length === 0 && <p className="muted">발급한 링크 없음</p>}
        {invites && invites.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>지원자</th>
                <th>상태</th>
                <th>발급</th>
                <th>감독 신호</th>
                <th>링크</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {invites.map((i) => (
                <tr key={i.id}>
                  <td>
                    <Link to={`/instructor/cohorts/${cohort.id}/exam-invites/${i.id}/report`}>{i.label}</Link>
                  </td>
                  <td>
                    <span className="tag">{STATUS_LABEL[i.status]}</span>
                  </td>
                  <td>{formatTime(i.created_at)}</td>
                  <td>
                    {(i.event_count ?? 0) > 0 ? (
                      <button
                        className="link"
                        onClick={() =>
                          eventsOf?.id === i.id
                            ? setEventsOf(null)
                            : run(async () => setEventsOf({ id: i.id, events: await instructor.examEvents(cohort.id, i.id) }), "감독 기록")
                        }
                      >
                        {i.event_count}건
                      </button>
                    ) : (
                      0
                    )}
                    {eventsOf?.id === i.id && (
                      <ol className="muted">
                        {eventsOf.events.map((e, n) => (
                          <li key={n}>
                            {formatTime(e.at)} {SIGNAL_LABEL[e.kind] ?? e.kind}
                            {e.detail && ` — ${e.detail}`}
                          </li>
                        ))}
                      </ol>
                    )}
                  </td>
                  <td>
                    {i.status !== "revoked" && (
                      <>
                        <code>{examInviteUrl(i.token)}</code> <button onClick={() => copy(i)}>{copied === i.id ? "복사됨" : "복사"}</button>
                      </>
                    )}
                  </td>
                  <td className="right">
                    {i.status !== "revoked" && (
                      <button
                        className="link"
                        disabled={busy}
                        onClick={() =>
                          run(async () => {
                            await instructor.revokeExamInvite(cohort.id, i.id);
                            setInvites((prev) =>
                              prev ? prev.map((x) => (x.id === i.id ? { ...x, status: "revoked" } : x)) : prev,
                            );
                          }, "회수")
                        }
                      >
                        회수
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </>
  );
}
