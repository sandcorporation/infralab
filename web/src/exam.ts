// 시험 모드 화면이 쓰는 순수 함수와 요청 — 응시 화면(#71·#72·#78), 시험 대시보드(#77).
// 인수 시험: src/spec/spec_exam_*.test.ts

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
export function remainingSecondsAt(_deadline: string, _serverTime: string, _elapsedMs: number): number {
  throw new Error("#71");
}

/** 남은 시간 표시 — 한 시간 이상은 H:MM:SS, 미만은 MM:SS. */
export function formatRemaining(_seconds: number): string {
  throw new Error("#71");
}

/** 동의를 실어 시험을 시작한다(POST /api/exam/<토큰>/start). */
export function startExam(_token: string): Promise<ExamStatus> {
  throw new Error("#71");
}

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
