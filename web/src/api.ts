// 서버 API 클라이언트. 인증은 backend 의 Django 세션 쿠키(HttpOnly)다 — 화면은 토큰을 갖지 않는다.
// 로그인은 sandcorp-auth 로 가는 /api/auth/login(운영) 또는 개발용 /api/auth/dev-login.

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

/** 세션이 없거나 끝났을 때(401) 화면 전체에 알리는 이벤트 — AuthProvider 가 듣고 로그아웃 상태로 바꾼다. */
export const UNAUTHENTICATED_EVENT = "infralab:unauthenticated";

/** auth 로그인 시작 주소. 돌아올 경로는 같은 사이트 경로만 backend 가 받는다. */
export function loginUrl(next: string): string {
  return `/api/auth/login?${new URLSearchParams({ next })}`;
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

/** 세션 쿠키를 실어 요청한다. 401 이면 로그아웃 상태를 알린다. 성공 응답만 돌려준다. */
async function request(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const res = await fetch(path, { ...init, headers, credentials: "same-origin" });
  if (res.status === 401) window.dispatchEvent(new Event(UNAUTHENTICATED_EVENT));
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

export type OrgRole = { id: number; name: string; role: "owner" | "staff" };
export type Me = { id: number; username: string; display_name: string; is_instructor: boolean; orgs: OrgRole[] };
export type OrgMemberRow = {
  id: number;
  user_id: number;
  username: string;
  display_name: string;
  role: "owner" | "staff";
  joined_at: string;
};
export type OrgInvite = { id: number; token: string; role: "owner" | "staff"; created_at: string; expires_at: string };
export type OrgInvitePreview = { org_name: string; role: "owner" | "staff"; valid: boolean };
export type CohortKind = "class" | "exam";
export type Cohort = {
  id: number;
  org_id: number;
  name: string;
  kind: CohortKind;
  exam_settings: Record<string, unknown>;
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
export type ExamTool = "claude_code" | "codex" | "local_llm";
export type ExamSettings = {
  time_limit_minutes: number;
  tools: ExamTool[];
  models: Record<string, string>;
  proctoring: boolean;
  hidden_checks: boolean;
  ai_token_limit: number;
};
export type ExamInvite = {
  id: number;
  label: string;
  token: string;
  status: "invited" | "in_progress" | "finished" | "revoked";
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  event_count?: number;
};
export type ExamEvent = { kind: string; detail: string; at: string };
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
  /** 「지켜야 할 것」 검사. 점수는 똑같이 센다. */
  constraint: boolean;
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
  /** AI 대화 기록이 붙은 제출인가. */
  has_transcript: boolean;
};
export type TranscriptEntry = { role: "user" | "assistant"; at: string; text: string };
export type ToolTranscript = { tool: "claude" | "codex"; since: string; truncated: boolean; entries: TranscriptEntry[] };
export type Submission = SubmissionSummary & { results: SubmittedResult[]; ai_transcript: ToolTranscript[] | null };
export type GridCell = {
  submission_id: number;
  passed: number;
  total: number;
  submitted_at: string;
  agent_version: string;
  has_transcript: boolean;
};
export type GridRow = {
  membership_id: number;
  user_id: number;
  username: string;
  display_name: string;
  cells: Record<string, GridCell | null>;
};
export type Grid = { scenarios: { id: string; title: string; total: number }[]; rows: GridRow[] };

// ---------- 호출 ----------

export const devLogin = (uid: string, nickname: string) =>
  api<void>("/api/auth/dev-login", { method: "POST", body: JSON.stringify({ uid, nickname }) });
export const logoutSession = () => api<void>("/api/auth/logout", { method: "POST" });
export const getMe = () => api<Me>("/api/accounts/me");
export const getMyCohorts = () => api<MyCohort[]>("/api/cohorts");
export const getMyCohort = (id: number) => api<MyCohortDetail>(`/api/cohorts/${id}`);
export const regenerateAgentToken = (id: number) =>
  api<MyCohortDetail>(`/api/cohorts/${id}/agent-token/regenerate`, { method: "POST" });

export const getCohortScenarios = (cohortId: number) =>
  api<StudentScenarioSummary[]>(`/api/cohorts/${cohortId}/scenarios`);
export const getCohortScenario = (cohortId: number, scenarioId: string) =>
  api<ScenarioDetail>(`/api/cohorts/${cohortId}/scenarios/${encodeURIComponent(scenarioId)}`);
/** 「환경 준비」 전용 응답 — 에이전트 /api/setup 에 그대로 넘기는 재료. */
export type Prepare = {
  scenario_id: string;
  setup: { command: string; scripts: Record<string, string>; timeout_seconds: number } | null;
  setup_reset: "floci" | "kind" | "both" | "none";
  kind: KindRequirement | null;
  ai_rules: string;
};
export const getPrepare = (cohortId: number, scenarioId: string) =>
  api<Prepare>(`/api/cohorts/${cohortId}/scenarios/${encodeURIComponent(scenarioId)}/prepare`);
export const submitResults = (
  cohortId: number,
  scenarioId: string,
  body: { agent_version: string; results: unknown[]; ai_transcript?: ToolTranscript[] },
) =>
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
  createCohort: (name: string, orgId: number, kind: CohortKind = "class") =>
    api<Cohort>("/api/instructor/cohorts", { method: "POST", body: JSON.stringify({ name, org_id: orgId, kind }) }),
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
  setExamSettings: (cohortId: number, settings: ExamSettings) =>
    api<Cohort>(`/api/instructor/cohorts/${cohortId}/exam-settings`, {
      method: "PUT",
      body: JSON.stringify(settings),
    }),
  examInvites: (cohortId: number) => api<ExamInvite[]>(`/api/instructor/cohorts/${cohortId}/exam-invites`),
  createExamInvite: (cohortId: number, label: string) =>
    api<ExamInvite>(`/api/instructor/cohorts/${cohortId}/exam-invites`, {
      method: "POST",
      body: JSON.stringify({ label }),
    }),
  examEvents: (cohortId: number, inviteId: number) =>
    api<ExamEvent[]>(`/api/instructor/cohorts/${cohortId}/exam-invites/${inviteId}/events`),
  revokeExamInvite: (cohortId: number, inviteId: number) =>
    api<void>(`/api/instructor/cohorts/${cohortId}/exam-invites/${inviteId}`, { method: "DELETE" }),
};

export const previewOrgInvite = (token: string) =>
  api<OrgInvitePreview>(`/api/org-invites/${encodeURIComponent(token)}`);
export const acceptOrgInvite = (token: string) =>
  api<{ org_id: number; org_name: string; role: "owner" | "staff"; created: boolean }>(
    `/api/org-invites/${encodeURIComponent(token)}/accept`,
    { method: "POST" },
  );
export const orgAdmin = {
  members: (orgId: number) => api<OrgMemberRow[]>(`/api/instructor/orgs/${orgId}/members`),
  setRole: (orgId: number, memberId: number, role: "owner" | "staff") =>
    api<OrgMemberRow>(`/api/instructor/orgs/${orgId}/members/${memberId}`, {
      method: "PATCH",
      body: JSON.stringify({ role }),
    }),
  remove: (orgId: number, memberId: number) =>
    api<void>(`/api/instructor/orgs/${orgId}/members/${memberId}`, { method: "DELETE" }),
  invites: (orgId: number) => api<OrgInvite[]>(`/api/instructor/orgs/${orgId}/invites`),
  createInvite: (orgId: number, role: "owner" | "staff") =>
    api<OrgInvite>(`/api/instructor/orgs/${orgId}/invites`, { method: "POST", body: JSON.stringify({ role }) }),
  revokeInvite: (orgId: number, inviteId: number) =>
    api<void>(`/api/instructor/orgs/${orgId}/invites/${inviteId}`, { method: "DELETE" }),
};

export function orgInviteUrl(token: string): string {
  return `${location.origin}/org-invite/${token}`;
}

export function examInviteUrl(token: string): string {
  return `${location.origin}/exam/${token}`;
}

export function joinUrl(token: string): string {
  return `${location.origin}/join/${token}`;
}

export function formatTime(iso: string): string {
  return new Date(iso).toLocaleString("ko-KR", { dateStyle: "short", timeStyle: "short" });
}
