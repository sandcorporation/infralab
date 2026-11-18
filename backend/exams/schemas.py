from __future__ import annotations

from datetime import datetime
from typing import Literal

from ninja import Field, Schema
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
