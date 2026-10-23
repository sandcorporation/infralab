import { formatTime, type ToolTranscript } from "../api";

const TOOL_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex" };

/** 제출에 붙은 AI 대화 — 접이식 구역. 도구별로 사용자/어시스턴트 발화를 시간순으로 보인다. */
export function TranscriptView({ transcript }: { transcript: ToolTranscript[] | null }) {
  if (!transcript || transcript.every((t) => t.entries.length === 0)) {
    return (
      <details className="transcript">
        <summary>AI 대화</summary>
        <p className="muted">기록 없음</p>
      </details>
    );
  }
  return (
    <details className="transcript" open>
      <summary>AI 대화</summary>
      {transcript
        .filter((t) => t.entries.length > 0)
        .map((t) => (
          <div key={t.tool} className="transcript-tool">
            <h4>
              {TOOL_NAMES[t.tool] ?? t.tool} <span className="muted small">{t.entries.length}개</span>
              {t.truncated && <span className="stale small"> · 잘림</span>}
            </h4>
            <ol className="chat">
              {t.entries.map((e, i) => (
                <li key={i} className={e.role}>
                  <div className="muted small">
                    {e.role === "user" ? "학생" : "AI"}
                    {e.at && ` · ${formatTime(e.at)}`}
                  </div>
                  <div className="chat-text">{e.text}</div>
                </li>
              ))}
            </ol>
          </div>
        ))}
    </details>
  );
}

/** 이력·격자 칸의 기록 유무 표시. */
export function TranscriptMark({ has }: { has: boolean }) {
  return has ? (
    <span className="tag small" title="AI 대화 있음">
      대화
    </span>
  ) : null;
}
