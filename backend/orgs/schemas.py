from __future__ import annotations

from datetime import datetime
from typing import Literal

from ninja import Schema


class MemberOut(Schema):
    id: int
    user_id: int
    username: str
    display_name: str
    role: str
    joined_at: datetime


class MemberUpdateIn(Schema):
    role: Literal["owner", "staff"]


class InviteCreateIn(Schema):
    role: Literal["owner", "staff"] = "staff"


class InviteOut(Schema):
    id: int
    token: str
    role: str
    created_at: datetime
    expires_at: datetime


class InvitePreviewOut(Schema):
    org_name: str
    role: str
    #: 수락할 수 있는 링크인가(만료·닫힘이면 False).
    valid: bool


class InviteAcceptOut(Schema):
    org_id: int
    org_name: str
    role: str
    created: bool
