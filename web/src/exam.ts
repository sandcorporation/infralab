// 시험 모드 화면이 쓰는 순수 함수와 요청 — 응시 화면(#71·#72·#78), 시험 대시보드(#77).
// 인수 시험: src/spec/spec_exam_*.test.ts
import { api } from "./api";

/** GET·POST /api/exam/<토큰> 의 응시 상태(backend ExamStatusOut). 시각은 ISO 글. */
export type ExamStatus = {
  cohort_id: number;
  cohort_name: string;
  status: "invited" | "in_progress" | "finished";
  time_limit_minutes: number;
  tools: string[];
  proctoring: boolean;
  started_at: string | null;
  deadline: string | null;
  remaining_seconds: number | null;
  server_time: string;
};

/** GET /api/exam/<토큰>/ai-config — 허용 도구마다 workstation 터미널에 붙여 넣을 설정. */
export type AiConfig = {
  proxy_url: string;
  token: string;
  tools: { tool: string; model: string; env: Record<string, string>; config_toml: string }[];
};

/** agent GET /api/preflight 의 응시 전 점검 결과. */
export type Preflight = {
  ok: boolean;
  checks: { id: "engine" | "linux_mode" | "permission"; ok: boolean; message: string; help_url: string }[];
};

/** 서버가 준 마감·서버 시각과 그 응답 뒤 흐른 시간(ms)으로 남은 초. 0 아래로 내려가지 않는다. */
export function remainingSecondsAt(deadline: string, serverTime: string, elapsedMs: number): number {
  const ms = Date.parse(deadline) - Date.parse(serverTime) - elapsedMs;
  // 올림: 마감 순간에 정확히 00:00 이 된다.
  return Number.isFinite(ms) ? Math.max(0, Math.ceil(ms / 1000)) : 0;
}

/** 남은 시간 표시 — 한 시간 이상은 H:MM:SS, 미만은 MM:SS. */
export function formatRemaining(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const mm = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const ss = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** 동의를 실어 시험을 시작한다(POST /api/exam/<토큰>/start). */
export function startExam(token: string): Promise<ExamStatus> {
  return api<ExamStatus>(`${examPath(token)}/start`, { method: "POST", body: JSON.stringify({ consent: true }) });
}

const examPath = (token: string) => `/api/exam/${encodeURIComponent(token)}`;

/** 응시 상태(로그인 없음). 없거나 회수된 링크면 404. */
export const getExamStatus = (token: string) => api<ExamStatus>(examPath(token));
/** 이 응시만을 위한 숨은 사용자로 세션을 연다. 같은 링크는 같은 응시로 돌아온다. */
export const enterExam = (token: string) => api<ExamStatus>(`${examPath(token)}/enter`, { method: "POST" });
/** 「제출하고 끝내기」 — 즉시 마감한다. */
export const finishExam = (token: string) => api<ExamStatus>(`${examPath(token)}/finish`, { method: "POST" });

/** 이 브라우저가 들어온 응시 링크 — 시나리오 화면에서도 남은 시간을 보이려고 기억한다. */
const EXAM_TOKEN_KEY = "infralab:exam-token";
export function rememberExamToken(token: string): void {
  try {
    localStorage.setItem(EXAM_TOKEN_KEY, token);
  } catch {
    /* 저장소를 못 쓰는 브라우저 — 응시 화면에서만 시간이 보인다 */
  }
}
export function rememberedExamToken(): string | null {
  try {
    return localStorage.getItem(EXAM_TOKEN_KEY);
  } catch {
    return null;
  }
}

/** 응시마다 만드는 숨은 사용자인가(backend exams.api.HIDDEN_USER_PREFIX). */
export const isExamUser = (username: string | undefined) => !!username?.startsWith("exam-invite:");

/** env 를 키 순서대로 `export K="V"` 줄로 잇는다(끝 줄바꿈 없음, 값 안의 " \ $ ` 는 앞에 \). */
export function envExportText(_env: Record<string, string>): string {
  throw new Error("#72");
}

/** AI 키 설정을 받는다(GET /api/exam/<토큰>/ai-config). */
export function getAiConfig(_token: string): Promise<AiConfig> {
  throw new Error("#72");
}

/** 점수 분포 막대 높이 — 가장 큰 구간을 1 로 둔 비율, 모두 0 이면 모두 0. */
export function bucketHeights(_buckets: number[]): number[] {
  throw new Error("#77");
}

/** 응시 전 점검 결과로 「시작」을 열지 정한다. 시험은 실패·미응답(null)이면 막고, 연습은 경고만 남긴다. */
export function preflightGate(
  _result: Preflight | null,
  _mode: "exam" | "practice",
): { canStart: boolean; warnings: string[] } {
  throw new Error("#78");
}
