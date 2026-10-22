// 서버 API 클라이언트. 토큰 쌍은 localStorage 에 두고(프로토타입), 401 이면 리프레시를 한 번 시도한다.

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export type TokenPair = { access: string; refresh: string };

const KEY = "infralab.tokens";

export function loadTokens(): TokenPair | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as TokenPair) : null;
  } catch {
    return null;
  }
}

export function saveTokens(t: TokenPair | null) {
  try {
    if (t) localStorage.setItem(KEY, JSON.stringify(t));
    else localStorage.removeItem(KEY);
  } catch {
    /* 저장소를 못 쓰면 이 탭에서만 로그인 상태다 */
  }
}

/** 토큰이 더 쓸 수 없게 됐을 때(리프레시 거부) 화면 전체에 알리는 이벤트 — AuthProvider 가 듣고 로그아웃 상태로 바꾼다. */
export const UNAUTHENTICATED_EVENT = "infralab:unauthenticated";

let refreshing: Promise<TokenPair | null> | null = null;

async function refreshTokens(): Promise<TokenPair | null> {
  const current = loadTokens();
  if (!current) return null;
  if (!refreshing) {
    refreshing = (async () => {
      const res = await fetch("/api/auth/refresh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh: current.refresh }),
      });
      if (res.status === 401) {
        saveTokens(null);
        window.dispatchEvent(new Event(UNAUTHENTICATED_EVENT));
        return null;
      }
      if (!res.ok) return null; // 일시적 오류 — 토큰은 남긴다
      const pair = (await res.json()) as TokenPair;
      saveTokens(pair);
      return pair;
    })().finally(() => {
      refreshing = null;
    });
  }
  return refreshing;
}

async function errorMessage(res: Response): Promise<string> {
  try {
    const body = await res.json();
    if (typeof body?.detail === "string") return body.detail;
    if (Array.isArray(body?.detail)) return body.detail.map((d: { msg?: string }) => d.msg ?? "").join(", ");
    if (typeof body?.error === "string") return body.error;
  } catch {
    /* 본문이 JSON 이 아니다 */
  }
  return `${res.status} ${res.statusText}`;
}

/** 인증 헤더를 붙여 요청하고, 401 이면 리프레시 뒤 한 번 다시 시도한다. 성공 응답만 돌려준다. */
async function request(path: string, init: RequestInit = {}, retry = true): Promise<Response> {
  const tokens = loadTokens();
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  if (tokens) headers.set("Authorization", `Bearer ${tokens.access}`);
  const res = await fetch(path, { ...init, headers });
  if (res.status === 401 && tokens && retry) {
    const fresh = await refreshTokens();
    if (fresh) return request(path, init, false);
  }
  if (!res.ok) throw new ApiError(res.status, await errorMessage(res));
  return res;
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await request(path, init);
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

export async function apiText(path: string, init: RequestInit = {}): Promise<string> {
  return (await request(path, init)).text();
}

// ---------- 타입 ----------

export type Me = { id: number; username: string; display_name: string; is_instructor: boolean };
export type Cohort = {
  id: number;
  name: string;
  join_token: string;
  join_open: boolean;
  archived: boolean;
  open_scenario_ids: string[];
  member_count: number;
  created_at: string;
};
export type MyCohort = { id: number; name: string; archived: boolean; joined_at: string };
export type MyCohortDetail = MyCohort & { agent_token: string; agent_url: string };
export type Participant = {
  membership_id: number;
  user_id: number;
  username: string;
  display_name: string;
  joined_at: string;
};
export type JoinPreview = { cohort_id: number; name: string; join_open: boolean };
export type KindRequirement = { control_planes: number; workers: number };
export type Requires = { floci: boolean; kind: KindRequirement | null };
export type ScenarioSummary = { id: string; title: string; requires: Requires; total: number };
export type StudentScenarioSummary = ScenarioSummary & { passed: number | null };
export type CheckDef = {
  id: string;
  name: string;
  hint: string;
  command: string;
  timeout_seconds: number;
  expect: Record<string, unknown> & { type: string };
};
export type ScenarioDetail = ScenarioSummary & { description: string; checks: CheckDef[]; scripts: Record<string, string> };
export type SubmittedResult = {
  check_id: string;
  name: string;
  pass: boolean;
  output: string;
  truncated: boolean;
  exit_code: number;
  error: string;
};
export type SubmissionSummary = {
  id: number;
  scenario_id: string;
  submitted_at: string;
  agent_version: string;
  passed: number;
  total: number;
};
export type Submission = SubmissionSummary & { results: SubmittedResult[] };
export type GridCell = { submission_id: number; passed: number; total: number; submitted_at: string; agent_version: string };
export type GridRow = {
  membership_id: number;
  user_id: number;
  username: string;
  display_name: string;
  cells: Record<string, GridCell | null>;
};
export type Grid = { scenarios: { id: string; title: string; total: number }[]; rows: GridRow[] };

// ---------- 호출 ----------

export const socialLogin = (provider: string, accessToken: string) =>
  api<TokenPair & { token_type: string }>(`/api/auth/social/${provider}/login`, {
    method: "POST",
    body: JSON.stringify({ access_token: accessToken }),
  });
export const getMe = () => api<Me>("/api/accounts/me");
export const getMyCohorts = () => api<MyCohort[]>("/api/cohorts");
export const getMyCohort = (id: number) => api<MyCohortDetail>(`/api/cohorts/${id}`);
export const regenerateAgentToken = (id: number) =>
  api<MyCohortDetail>(`/api/cohorts/${id}/agent-token/regenerate`, { method: "POST" });

export const getCohortScenarios = (cohortId: number) =>
  api<StudentScenarioSummary[]>(`/api/cohorts/${cohortId}/scenarios`);
export const getCohortScenario = (cohortId: number, scenarioId: string) =>
  api<ScenarioDetail>(`/api/cohorts/${cohortId}/scenarios/${encodeURIComponent(scenarioId)}`);
export const submitResults = (cohortId: number, scenarioId: string, body: { agent_version: string; results: unknown[] }) =>
  api<Submission>(`/api/cohorts/${cohortId}/scenarios/${encodeURIComponent(scenarioId)}/submissions`, {
    method: "POST",
    body: JSON.stringify(body),
  });
export const getLatestSubmission = async (cohortId: number, scenarioId: string): Promise<Submission | null> => {
  try {
    return await api<Submission>(`/api/cohorts/${cohortId}/scenarios/${encodeURIComponent(scenarioId)}/submissions/latest`);
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null;
    throw err;
  }
};

/** compose.yml 본문 — 내려받기와 복사 둘 다 이 텍스트를 쓴다. */
export const fetchComposeFile = (id: number) => apiText(`/api/cohorts/${id}/compose.yml`);

/** 라우트 파라미터의 기수 id. 숫자가 아니면 null — 서버에 NaN 을 보내 422 를 받지 않는다. */
export function parseId(raw: string | undefined): number | null {
  const n = Number(raw);
  return raw !== undefined && Number.isInteger(n) && n > 0 ? n : null;
}
export const previewJoin = (token: string) => api<JoinPreview>(`/api/join/${encodeURIComponent(token)}`);
export const join = (token: string) =>
  api<{ cohort_id: number; name: string; created: boolean }>(`/api/join/${encodeURIComponent(token)}`, {
    method: "POST",
  });
export const instructor = {
  cohorts: () => api<Cohort[]>("/api/instructor/cohorts"),
  cohort: (id: number) => api<Cohort>(`/api/instructor/cohorts/${id}`),
  createCohort: (name: string) =>
    api<Cohort>("/api/instructor/cohorts", { method: "POST", body: JSON.stringify({ name }) }),
  updateCohort: (id: number, patch: Partial<Pick<Cohort, "name" | "join_open" | "archived">>) =>
    api<Cohort>(`/api/instructor/cohorts/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),
  regenerateJoinToken: (id: number) =>
    api<Cohort>(`/api/instructor/cohorts/${id}/join-token/regenerate`, { method: "POST" }),
  participants: (id: number) => api<Participant[]>(`/api/instructor/cohorts/${id}/participants`),
  removeParticipant: (id: number, membershipId: number) =>
    api<void>(`/api/instructor/cohorts/${id}/participants/${membershipId}`, { method: "DELETE" }),
  grid: (cohortId: number) => api<Grid>(`/api/instructor/cohorts/${cohortId}/grid`),
  history: (cohortId: number, membershipId: number, scenarioId: string) =>
    api<SubmissionSummary[]>(
      `/api/instructor/cohorts/${cohortId}/participants/${membershipId}/scenarios/${encodeURIComponent(scenarioId)}/submissions`,
    ),
  submission: (id: number) => api<Submission>(`/api/instructor/submissions/${id}`),
  scenarios: () => api<ScenarioSummary[]>("/api/instructor/scenarios"),
  setOpenScenarios: (cohortId: number, scenarioIds: string[]) =>
    api<string[]>(`/api/instructor/cohorts/${cohortId}/scenarios`, {
      method: "PUT",
      body: JSON.stringify({ scenario_ids: scenarioIds }),
    }),
};

export function joinUrl(token: string): string {
  return `${location.origin}/join/${token}`;
}

export function formatTime(iso: string): string {
  return new Date(iso).toLocaleString("ko-KR", { dateStyle: "short", timeStyle: "short" });
}
