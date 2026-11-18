import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { Link } from "react-router-dom";
import { ConfirmDialog, Drawer, Modal } from "./ui";
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

export const SIGNAL_LABEL: Record<string, string> = {
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
export const STATUS_LABEL: Record<ExamInvite["status"], string> = {
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

/**
 * 허용 도구 체크박스. 공급사 키가 없는 도구는 고를 수 없다(이미 골라 둔 것은 풀 수만 있다).
 */
export function ToolOptions({
  form,
  unavailable,
  onToggle,
  onModel,
}: {
  form: ExamSettings;
  unavailable: readonly ExamTool[];
  onToggle: (tool: ExamTool) => void;
  onModel: (tool: ExamTool, model: string) => void;
}) {
  return (
    <fieldset>
      <legend>허용 도구 (비워 두면 AI 없는 시험)</legend>
      {TOOLS.map((t) => {
        const checked = form.tools.includes(t.key);
        const missing = unavailable.includes(t.key);
        return (
          <div className="row" key={t.key}>
            <label>
              <input type="checkbox" checked={checked} disabled={missing && !checked} onChange={() => onToggle(t.key)} />{" "}
              {t.label}
            </label>
            {missing && <span className="muted">공급사 키 없음</span>}
            {(t.key === "claude_code" || t.key === "codex") && checked && (
              <input
                placeholder="고정 모델"
                aria-label={`${t.label} 모델`}
                value={form.models[t.key] ?? ""}
                onChange={(e) => onModel(t.key, e.target.value)}
              />
            )}
          </div>
        );
      })}
    </fieldset>
  );
}

function initial(raw: Cohort["exam_settings"]): ExamSettings {
  return { ...DEFAULTS, ...(raw as Partial<ExamSettings>) };
}

export const examSettingsSaved = (cohort: Cohort) => Object.keys(cohort.exam_settings).length > 0;

/** 시험 회차 설정 폼(기수 상세 「설정」 탭). */
export function ExamSettingsForm({ cohort, onSaved }: { cohort: Cohort; onSaved: (c: Cohort) => void }) {
  const saved = examSettingsSaved(cohort);
  const [form, setForm] = useState<ExamSettings>(() => initial(cohort.exam_settings));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [unavailable, setUnavailable] = useState<ExamTool[]>([]);

  useEffect(() => {
    let cancelled = false;
    // 못 받으면 아무 도구도 막지 않는다 — 저장할 때 backend 가 다시 본다.
    instructor
      .examProviders()
      .then((r) => !cancelled && setUnavailable(r.unavailable_tools))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, []);

  function toggleTool(tool: ExamTool) {
    setDone(false);
    setForm((f) => ({
      ...f,
      tools: f.tools.includes(tool) ? f.tools.filter((t) => t !== tool) : [...f.tools, tool],
    }));
  }
  const edit = (patch: Partial<ExamSettings>) => {
    setDone(false);
    setForm((f) => ({ ...f, ...patch }));
  };

  async function save() {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      onSaved(await instructor.setExamSettings(cohort.id, form));
      setDone(true);
    } catch (e) {
      setError(`설정 저장 실패: ${(e as ApiError).message}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="row">
        <label>
          시간 제한(분)
          <input
            type="number"
            min={1}
            max={600}
            value={form.time_limit_minutes}
            onChange={(e) => edit({ time_limit_minutes: Number(e.target.value) })}
          />
        </label>
        <label>
          임시 토큰 한도(토큰, 0 = 무제한)
          <input type="number" min={0} value={form.ai_token_limit} onChange={(e) => edit({ ai_token_limit: Number(e.target.value) })} />
        </label>
      </div>
      <ToolOptions
        form={form}
        unavailable={unavailable}
        onToggle={toggleTool}
        onModel={(tool, model) => edit({ models: { ...form.models, [tool]: model } })}
      />
      <div className="row">
        <label>
          <input type="checkbox" checked={form.proctoring} onChange={(e) => edit({ proctoring: e.target.checked })} /> 감독
        </label>
        <label>
          <input type="checkbox" checked={form.hidden_checks} onChange={(e) => edit({ hidden_checks: e.target.checked })} /> 숨은 검사
          사용
        </label>
      </div>
      <div className="row actions">
        <button disabled={busy} onClick={save}>
          설정 저장
        </button>
        {!saved && <span className="muted">설정을 저장해야 응시 링크를 발급할 수 있습니다.</span>}
        {done && <span className="muted" role="status">저장됨</span>}
      </div>
      {error && <p className="error">{error}</p>}
    </>
  );
}

/** 응시 링크 표(기수 상세 「응시 링크」 탭): 발급(상자)·복사·회수(확인)·감독 신호(서랍). */
export function ExamInvites({ cohort }: { cohort: Cohort }) {
  const saved = examSettingsSaved(cohort);
  const [params, setParams] = useSearchParams();
  const issuing = params.get("new") === "1";
  const [invites, setInvites] = useState<ExamInvite[] | null>(null);
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState<number | null>(null);
  const [eventsOf, setEventsOf] = useState<{ invite: ExamInvite; events: ExamEvent[] } | null>(null);
  const [revoking, setRevoking] = useState<ExamInvite | null>(null);

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

  function setIssuing(open: boolean) {
    const next = new URLSearchParams(params);
    if (open) next.set("new", "1");
    else next.delete("new");
    setParams(next, { replace: true });
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

  const issue = () =>
    run(async () => {
      const created = await instructor.createExamInvite(cohort.id, label.trim());
      setInvites((prev) => [...(prev ?? []), created]);
      setLabel("");
      setIssuing(false);
    }, "링크 발급");

  return (
    <>
      <div className="toolbar-row">
        <button disabled={!saved} onClick={() => setIssuing(true)}>
          응시 링크 발급
        </button>
      </div>
      {!saved && (
        <div className="sc-alert" role="status">
          시험 설정을 저장해야 응시 링크를 발급할 수 있습니다. <Link to={`/instructor/cohorts/${cohort.id}/settings`}>설정으로</Link>
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {invites && invites.length === 0 && <p className="muted">발급한 링크 없음</p>}
      {invites && invites.length > 0 && (
        <div className="sc-table-scroll">
          <table className="sc-table">
            <thead>
              <tr>
                <th>지원자</th>
                <th>상태</th>
                <th>발급</th>
                <th className="sc-num">감독 신호</th>
                <th>링크</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {invites.map((i) => (
                <InviteRow
                  key={i.id}
                  cohortId={cohort.id}
                  invite={i}
                  copied={copied === i.id}
                  busy={busy}
                  onCopy={() => copy(i)}
                  onRevoke={() => setRevoking(i)}
                  onEvents={() =>
                    run(async () => setEventsOf({ invite: i, events: await instructor.examEvents(cohort.id, i.id) }), "감독 기록")
                  }
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        open={issuing}
        title="응시 링크 발급"
        onClose={() => setIssuing(false)}
        foot={
          <>
            <button type="button" className="secondary" onClick={() => setIssuing(false)}>
              취소
            </button>
            <button type="submit" form="issue-invite" disabled={busy || !saved || !label.trim()}>
              발급
            </button>
          </>
        }
      >
        <form
          id="issue-invite"
          onSubmit={(e) => {
            e.preventDefault();
            if (saved && label.trim()) issue();
          }}
        >
          <label>
            지원자 표시 이름(메모)
            <input autoFocus value={label} onChange={(e) => setLabel(e.target.value)} />
          </label>
        </form>
      </Modal>

      <ConfirmDialog
        open={revoking !== null}
        title="응시 링크 회수"
        confirmLabel="회수"
        busy={busy}
        onClose={() => setRevoking(null)}
        onConfirm={() =>
          revoking &&
          run(async () => {
            await instructor.revokeExamInvite(cohort.id, revoking.id);
            setInvites((prev) => (prev ? prev.map((x) => (x.id === revoking.id ? { ...x, status: "revoked" } : x)) : prev));
            setRevoking(null);
          }, "회수")
        }
      >
        <p>{revoking?.label} — 회수한 링크로는 응시할 수 없습니다.</p>
      </ConfirmDialog>

      <Drawer open={eventsOf !== null} title={`감독 신호 · ${eventsOf?.invite.label ?? ""}`} onClose={() => setEventsOf(null)}>
        <ol className="events">
          {eventsOf?.events.map((e, n) => (
            <li key={n}>
              <span className="muted">{formatTime(e.at)}</span> {SIGNAL_LABEL[e.kind] ?? e.kind}
              {e.detail && ` — ${e.detail}`}
            </li>
          ))}
        </ol>
      </Drawer>
    </>
  );
}

/** 끝난 응시는 회수하지 않는다(API 409) — 상태 「끝남」과 보고서 길을 지킨다(#154). */
export const canRevoke = (status: ExamInvite["status"]) => status === "invited" || status === "in_progress";

/** 응시 링크 표의 한 줄. 지원자 이름은 늘 보고서 링크. */
export function InviteRow({
  cohortId,
  invite: i,
  copied,
  busy,
  onCopy,
  onRevoke,
  onEvents,
}: {
  cohortId: number;
  invite: ExamInvite;
  copied: boolean;
  busy: boolean;
  onCopy: () => void;
  onRevoke: () => void;
  onEvents: () => void;
}) {
  return (
    <tr>
      <td>
        <Link to={`/instructor/cohorts/${cohortId}/exam-invites/${i.id}/report`}>{i.label}</Link>
      </td>
      <td>
        <span className="sc-badge sc-badge--neutral">{STATUS_LABEL[i.status]}</span>
      </td>
      <td>{formatTime(i.created_at)}</td>
      <td className="sc-num">
        {(i.event_count ?? 0) > 0 ? (
          <button className="link" onClick={onEvents}>
            {i.event_count}건
          </button>
        ) : (
          0
        )}
      </td>
      <td>
        {i.status !== "revoked" && (
          <button className="secondary" onClick={onCopy} title={examInviteUrl(i.token)}>
            {copied ? "복사됨" : "링크 복사"}
          </button>
        )}
      </td>
      <td className="right">
        {canRevoke(i.status) && (
          <button className="link" disabled={busy} onClick={onRevoke}>
            회수
          </button>
        )}
      </td>
    </tr>
  );
}
