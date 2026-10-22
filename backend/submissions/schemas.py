from __future__ import annotations

from datetime import datetime

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


class SubmissionIn(Schema):
    agent_version: str = ""
    results: list[CheckResultIn]


class SubmissionSummaryOut(Schema):
    id: int
    scenario_id: str
    submitted_at: datetime
    agent_version: str
    passed: int
    total: int


class SubmissionOut(SubmissionSummaryOut):
    #: [{check_id, name, pass, output, truncated, exit_code, error}] — 저장된 JSON 그대로. `pass` 는 파이썬 예약어라
    #: 필드 모델 대신 dict 로 내보낸다.
    results: list[dict]
