import { useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ApiError } from "../api";
import { useAuth } from "../auth";
import {
  enterExam,
  envExportText,
  finishExam,
  formatRemaining,
  getAiConfig,
  rememberExamToken,
  startExam,
} from "../exam";
import type { AiConfig } from "../exam";
import { useExamClock } from "../examAttempt";

const TOOL_LABELS: Record<string, string> = {
  claude_code: "Claude Code",
  codex: "Codex",
  local_llm: "로컬 LLM",
};

// 응시 링크(/exam/<토큰>). 가입하지 않는다 — 링크를 열면 이 응시만을 위한 세션을 받고(enter), 안내·동의 뒤
// 「시작」을 누르면 시간이 흐른다. 같은 링크를 다시 열면 같은 응시로 돌아온다.
export default function ExamPage() {
  const { token = "" } = useParams();
  const { refreshMe } = useAuth();
  const clock = useExamClock();
  const [error, setError] = useState<string | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState(false);
  // StrictMode 가 effect 를 두 번 돌려도 enter 는 한 번만.
  const entered = useRef<string | null>(null);
  const apply = clock?.apply;

  useEffect(() => {
    if (!apply || entered.current === token) return;
    entered.current = token;
    enterExam(token)
      .then((s) => {
        rememberExamToken(token);
        apply(s);
        return refreshMe();
      })
      .catch((err: ApiError) => setError(err.status === 404 ? "응시 링크가 올바르지 않거나 회수되었습니다." : err.message));
  }, [token, apply, refreshMe]);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      await clock?.refresh();
    } finally {
      setBusy(false);
    }
  }

  const start = () => run(async () => clock?.apply(await startExam(token)));
  const finish = () => {
    if (!confirm("제출하고 시험을 끝냅니다. 끝낸 뒤에는 더 제출할 수 없습니다.")) return;
    void run(async () => clock?.apply(await finishExam(token)));
  };

  const status = clock?.status;
  return (
    <section className="card narrow">
      <h1>{status?.cohort_name ?? "시험"}</h1>
      {error && <p className="error">{error}</p>}
      {!error && !status && <p className="muted">확인 중…</p>}
      {status && status.status === "invited" && (
        <>
          <ul>
            <li>시간 제한: {status.time_limit_minutes}분 — 「시작」을 누른 때부터 흐릅니다.</li>
            <li>
              허용 AI 도구:{" "}
              {status.tools.length ? status.tools.map((t) => TOOL_LABELS[t] ?? t).join(", ") : "없음"}
            </li>
            {status.proctoring && <li>이 시험은 감독합니다 — 응시 중 화면 이탈 같은 신호가 기록됩니다.</li>}
            <li>시간이 끝나거나 「제출하고 끝내기」를 누르면 더 제출할 수 없습니다.</li>
          </ul>
          <label className="row">
            <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
            위 안내를 읽었고 동의합니다.
          </label>
          <p>
            <button onClick={() => void start()} disabled={!consent || busy}>
              시작
            </button>
          </p>
        </>
      )}
      {status && status.status !== "invited" && !clock.finished && (
        <>
          <p>
            남은 시간 <strong className="exam-clock">{formatRemaining(clock.remaining ?? 0)}</strong>
          </p>
          <p>
            <Link className="button" to={`/cohorts/${status.cohort_id}`}>
              시나리오로 가기
            </Link>
          </p>
          {status.tools.some((t) => t === "claude_code" || t === "codex") && <AiKeySetup token={token} />}
          <p>
            <button className="secondary" onClick={finish} disabled={busy}>
              제출하고 끝내기
            </button>
          </p>
        </>
      )}
      {status && clock.finished && (
        <p className="notice">시험이 마감되었습니다. 수고하셨습니다 — 더 제출할 수 없습니다.</p>
      )}
    </section>
  );
}

// 「AI 키 설정」 — 회차가 허용한 도구마다 workstation 터미널에 붙여 넣을 글. 키는 응시 한 번짜리 임시 토큰이다.
function AiKeySetup({ token }: { token: string }) {
  const [config, setConfig] = useState<AiConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    getAiConfig(token)
      .then((c) => alive && setConfig(c))
      .catch((err: ApiError) => alive && setError(err.message));
    return () => {
      alive = false;
    };
  }, [token]);

  async function copy(key: string, text: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(key);
    } catch {
      setError("복사하지 못했습니다 — 글을 직접 골라 복사하세요.");
    }
  }

  return (
    <div className="ai-key-setup">
      <h2>AI 키 설정</h2>
      {error && <p className="error">{error}</p>}
      {!error && !config && <p className="muted">불러오는 중…</p>}
      {config?.tools.map((t) => {
        const envText = envExportText(t.env);
        return (
          <div key={t.tool}>
            <h3>
              {TOOL_LABELS[t.tool] ?? t.tool} <span className="muted">({t.model})</span>
            </h3>
            {t.config_toml && (
              <>
                <p className="muted">설정 파일 ~/.codex/config.toml 에 넣으세요.</p>
                <pre>{t.config_toml}</pre>
                <p>
                  <button className="secondary" onClick={() => void copy(`${t.tool}:toml`, t.config_toml)}>
                    {copied === `${t.tool}:toml` ? "복사했습니다" : "설정 파일 복사"}
                  </button>
                </p>
              </>
            )}
            <p className="muted">workstation 터미널에 붙여 넣으세요.</p>
            <pre>{envText}</pre>
            <p>
              <button className="secondary" onClick={() => void copy(`${t.tool}:env`, envText)}>
                {copied === `${t.tool}:env` ? "복사했습니다" : "환경변수 복사"}
              </button>
            </p>
          </div>
        );
      })}
      {config && <p className="muted">이 키는 이 응시에서만, 시험 시간 안에만 쓸 수 있습니다.</p>}
    </div>
  );
}
