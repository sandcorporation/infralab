from __future__ import annotations

from datetime import datetime
from typing import Literal

from ninja import Field, Schema


class CheckResultIn(Schema):
    """에이전트 /api/check 응답의 results[] 한 칸을 그대로 올린다."""

    id: str
    name: str = ""
    hint: str = ""
    pass_: bool = Field(alias="pass")
    output: str = ""
    truncated: bool = False
    exit_code: int = 0
    error: str = ""


class TranscriptEntryIn(Schema):
    role: Literal["user", "assistant"]
    at: str = ""
    text: str


class ToolTranscriptIn(Schema):
    """에이전트 /api/ai-transcript 응답의 transcripts[] 한 칸."""

    tool: Literal["claude", "codex"]
    since: str = ""
    truncated: bool = False
    entries: list[TranscriptEntryIn]


class SubmissionIn(Schema):
    agent_version: str = ""
    results: list[CheckResultIn]
    #: 선택 — 학생이 끌 수 있다. 도구마다 하나.
    ai_transcript: list[ToolTranscriptIn] | None = None


class SubmissionSummaryOut(Schema):
    id: int
    scenario_id: str
    submitted_at: datetime
    agent_version: str
    passed: int
    total: int
    #: 발화가 하나라도 붙은 제출인가. 끈 것과 AI 를 안 쓴 것은 구분하지 않는다(둘 다 false).
    has_transcript: bool


class SubmissionOut(SubmissionSummaryOut):
    #: [{tool, since, truncated, entries:[{role, at, text}]}] 저장된 그대로. 기록이 없으면 null.
    ai_transcript: list[dict] | None
    #: [{check_id, name, pass, output, truncated, exit_code, error}] — 저장된 JSON 그대로. `pass` 는 파이썬 예약어라
    #: 필드 모델 대신 dict 로 내보낸다.
    results: list[dict]
