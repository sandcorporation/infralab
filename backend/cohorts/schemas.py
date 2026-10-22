from __future__ import annotations

from datetime import datetime

from ninja import Field, Schema
from pydantic import field_validator


def _clean_name(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("이름이 비어 있습니다.")
    return value


class CohortCreateIn(Schema):
    name: str = Field(max_length=100)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return _clean_name(v)


class CohortUpdateIn(Schema):
    name: str | None = Field(default=None, max_length=100)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return None if v is None else _clean_name(v)


class CohortOut(Schema):
    """강사가 보는 기수."""

    id: int
    name: str
    join_token: str
    join_open: bool
    archived: bool
    open_scenario_ids: list[str]
    member_count: int
    created_at: datetime


class ParticipantOut(Schema):
    membership_id: int
    user_id: int
    username: str
    display_name: str
    joined_at: datetime


class JoinPreviewOut(Schema):
    """로그인 전에도 보이는 가입 미리보기 — 기수 이름과 열림 여부만."""

    cohort_id: int
    name: str
    join_open: bool


class JoinOut(Schema):
    cohort_id: int
    name: str
    created: bool


class MyCohortOut(Schema):
    """학생이 보는 내 기수."""

    id: int
    name: str
    archived: bool
    joined_at: datetime
