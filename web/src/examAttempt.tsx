import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ConfirmDialog } from "./components/ui";
import { finishExam, formatRemaining, getExamStatus, postExamEvent, remainingSecondsAt, watchProctorSignals, type ExamStatus } from "./exam";

// 지원자의 응시 상태와 남은 시간. 남은 시간은 서버가 준 deadline·server_time 과 그 응답 뒤 흐른 시간으로 센다 —
// 브라우저 시계가 틀려도 같다. 30초마다 서버에 다시 물어 「끝내기」·회수·시간 설정 변경을 따라간다.

type Clock = {
  token: string;
  status: ExamStatus | null;
  /** 남은 초. 시작 전이면 null. */
  remaining: number | null;
  /** 시간이 다 됐거나 끝냈다 — 제출이 막힌다. */
  finished: boolean;
  error: string | null;
  /** 서버가 준 새 상태(시작·끝내기 응답)를 바로 반영한다. */
  apply: (s: ExamStatus) => void;
  refresh: () => Promise<void>;
};

const ExamClockContext = createContext<Clock | null>(null);

const REFRESH_MS = 30_000;

export function ExamClockProvider({ token, children }: { token: string | null; children: ReactNode }) {
  const [status, setStatus] = useState<ExamStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const receivedAt = useRef(0);
  const [now, setNow] = useState(() => performance.now());

  const apply = useCallback((s: ExamStatus) => {
    receivedAt.current = performance.now();
    setNow(receivedAt.current);
    setStatus(s);
    setError(null);
  }, []);

  const refresh = useCallback(async () => {
    if (!token) return;
    try {
      apply(await getExamStatus(token));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [token, apply]);

  useEffect(() => {
    setStatus(null);
    setError(null);
    if (!token) return;
    void refresh();
    const timer = setInterval(() => void refresh(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [token, refresh]);

  useEffect(() => {
    if (status?.status !== "in_progress") return;
    const timer = setInterval(() => setNow(performance.now()), 1000);
    return () => clearInterval(timer);
  }, [status?.status]);

  const watching = !!token && status?.status === "in_progress" && status.proctoring;
  useEffect(() => {
    if (!watching || !token) return;
    return watchProctorSignals(window, document, (kind, detail) => {
      postExamEvent(token, kind, detail).catch(() => {
        /* 신호를 못 보내도 응시를 막지 않는다 */
      });
    });
  }, [watching, token]);

  const remaining =
    status?.deadline != null ? remainingSecondsAt(status.deadline, status.server_time, now - receivedAt.current) : null;
  const finished = status?.status === "finished" || (status?.status === "in_progress" && remaining === 0);

  const value = useMemo<Clock | null>(
    () => (token ? { token, status, remaining, finished, error, apply, refresh } : null),
    [token, status, remaining, finished, error, apply, refresh],
  );
  return <ExamClockContext.Provider value={value}>{children}</ExamClockContext.Provider>;
}

/** 지금 응시 중인 시험의 시계. 응시자가 아니면 null. */
export function useExamClock(): Clock | null {
  return useContext(ExamClockContext);
}

/** 상단 띠(고정) — 회차 이름, 남은 시간(또는 마감), 「제출하고 끝내기」. 디자인시스템의 띠 요소는 sandcorp-design#27. */
export function ExamBar() {
  const clock = useExamClock();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!clock?.status) return null;
  const { status, remaining, finished } = clock;
  const finish = async () => {
    setBusy(true);
    setError(null);
    try {
      clock.apply(await finishExam(clock.token));
      setConfirming(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      await clock.refresh();
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={`exam-bar${finished ? " ended" : ""}`} role="status">
      <Link to={`/exam/${encodeURIComponent(clock.token)}`}>{status.cohort_name}</Link>
      {status.status === "invited" && <span className="muted">시작 전</span>}
      {status.status !== "invited" &&
        (finished ? (
          <strong>마감 — 더 제출할 수 없습니다</strong>
        ) : (
          <>
            <span>
              남은 시간 <strong className="exam-clock">{formatRemaining(remaining ?? 0)}</strong>
            </span>
            <button type="button" className="sc-btn sc-btn--sm" onClick={() => setConfirming(true)}>
              제출하고 끝내기
            </button>
          </>
        ))}
      <ConfirmDialog
        open={confirming}
        title="제출하고 끝내기"
        confirmLabel="끝내기"
        busy={busy}
        onConfirm={() => void finish()}
        onClose={() => setConfirming(false)}
      >
        <p>끝낸 뒤에는 더 제출할 수 없습니다.</p>
        {error && <p className="error">{error}</p>}
      </ConfirmDialog>
    </div>
  );
}
