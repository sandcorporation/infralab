from __future__ import annotations

from datetime import datetime
from typing import Literal

from ninja import Field, Schema
from scenarios.schemas import CheckOut
from submissions.schemas import CheckResultIn
from pydantic import field_validator, model_validator

Tool = Literal["claude_code", "codex", "local_llm"]
#: 고정 모델을 정해야 하는 도구.
MODEL_TOOLS = ("claude_code", "codex")


class ExamSettingsIn(Schema):
    time_limit_minutes: int = Field(ge=1, le=600)
    tools: list[Tool]
    models: dict[str, str] = Field(default_factory=dict)
    proctoring: bool
    hidden_checks: bool
    ai_token_limit: int = Field(ge=0)

    @field_validator("tools")
    @classmethod
    def _unique_tools(cls, v: list[str]) -> list[str]:
        return list(dict.fromkeys(v))

    @model_validator(mode="after")
    def _models_for_tools(self):
        for tool in MODEL_TOOLS:
            if tool in self.tools and not self.models.get(tool, "").strip():
                raise ValueError(f"{tool} 의 모델을 정해야 합니다.")
        return self

    def normalized(self) -> dict:
        return {
            "time_limit_minutes": self.time_limit_minutes,
            "tools": list(self.tools),
            "models": {t: self.models[t].strip() for t in MODEL_TOOLS if t in self.tools},
            "proctoring": self.proctoring,
            "hidden_checks": self.hidden_checks,
            "ai_token_limit": self.ai_token_limit,
        }


class ExamInviteIn(Schema):
    label: str = Field(max_length=100)

    @field_validator("label")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("지원자 이름이 비어 있습니다.")
        return v


class ExamInviteOut(Schema):
    id: int
    label: str
    token: str
    status: Literal["invited", "in_progress", "finished", "revoked"]
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None
    event_count: int = 0


class ExamEventIn(Schema):
    kind: Literal["tab_hidden", "focus_lost", "paste"]
    detail: str = Field(default="", max_length=2000)


class ExamEventOut(Schema):
    kind: str
    detail: str
    at: datetime


class ExamStatusOut(Schema):
    """지원자가 보는 응시 상태. 남은 시간은 `server_time` 과 `deadline` 으로 화면이 센다."""

    cohort_id: int
    cohort_name: str
    status: Literal["invited", "in_progress", "finished"]
    time_limit_minutes: int
    tools: list[str]
    proctoring: bool
    started_at: datetime | None
    deadline: datetime | None
    remaining_seconds: int | None
    server_time: datetime


class ExamEnterOut(ExamStatusOut):
    """enter 의 답. `replaced_login` — 이 브라우저에 있던 다른 사용자의 로그인을 응시 세션으로 바꿨다."""

    replaced_login: bool


class ExamStartIn(Schema):
    consent: bool


class ExamProvidersOut(Schema):
    """시험 설정에서 고를 수 없는 도구 — 그 도구의 공급사 키가 AI 프록시에 없다. 프록시를 못 부르면 빈 목록."""

    unavailable_tools: list[Tool]


class AiToolConfigOut(Schema):
    tool: str
    model: str
    env: dict[str, str]
    #: Codex 설정 파일(~/.codex/config.toml) 내용. Claude Code 는 빈 글.
    config_toml: str


class AiConfigOut(Schema):
    """지원자가 workstation 터미널에 붙여 넣을 AI 키 설정. 키는 진짜 공급사 키가 아닌 임시 토큰이다."""

    proxy_url: str
    token: str
    tools: list[AiToolConfigOut]


class ProxyAuthorizeIn(Schema):
    token: str
    #: claude_code·codex 가 아니면 `tool_not_allowed` 로 거절한다.
    tool: str
    client_id: str = Field(max_length=200)


class ProxyVerdictOut(Schema):
    allowed: bool
    reason: Literal["unknown", "revoked", "outside_window", "tool_not_allowed", "limit", "in_use_elsewhere"] | None
    model: str | None
    remaining_tokens: int | None


class ProxyExchangeIn(Schema):
    token: str
    tool: str = Field(max_length=20)
    model: str = Field(default="", max_length=200)
    client_id: str = Field(default="", max_length=200)
    input_tokens: int = Field(ge=0)
    output_tokens: int = Field(ge=0)
    # input_tokens 에 이미 들어 있는 캐시 입력. 옛 프록시는 보내지 않는다(#252).
    cache_read_input_tokens: int | None = Field(default=None, ge=0)
    cache_creation_input_tokens: int | None = Field(default=None, ge=0)
    request: str = ""
    response: str = ""


class FinalChecksScenarioOut(Schema):
    scenario_id: str
    checks: list[CheckOut]
    scripts: dict[str, str]


class FinalChecksOut(Schema):
    scenarios: list[FinalChecksScenarioOut]


class FinalResultsScenarioIn(Schema):
    scenario_id: str
    results: list[CheckResultIn]


class FinalResultsIn(Schema):
    agent_version: str = ""
    scenarios: list[FinalResultsScenarioIn]


class ExamScoreOut(Schema):
    public_passed: int
    public_total: int
    hidden_passed: int
    hidden_total: int
    hidden_status: Literal["done", "pending", "skipped"]
    final_percent: int | None


class RubricItemOut(Schema):
    key: str
    label: str
    score: int
    llm_score: int
    evidence: list[str]
    edited: bool


class RubricOut(Schema):
    grader: str
    graded_at: datetime
    items: list[RubricItemOut]


class RubricEditOut(Schema):
    key: str
    from_score: int
    to_score: int
    reason: str
    by: str
    at: datetime


class ExamReportOut(Schema):
    """지원자 보고서 — 결과 점수와 과정 루브릭(채점 전엔 null), 담당자 수정 이력(#76)."""

    invite_id: int
    label: str
    status: Literal["invited", "in_progress", "finished", "revoked"]
    score: ExamScoreOut
    rubric: RubricOut | None
    local_model_unverified: bool
    edits: list[RubricEditOut]


class RubricEditIn(Schema):
    score: int = Field(ge=0, le=5)
    reason: str = Field(max_length=2000)

    @field_validator("reason")
    @classmethod
    def _reason(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("사유를 적어야 합니다.")
        return v
