"""응시 링크 발송기. 메일은 보내지 않는다 — 인터페이스와 보내지 않는 기본 구현만 둔다(#70)."""

from __future__ import annotations

from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from .models import ExamInvite


class InviteSender(Protocol):
    def send(self, invite: ExamInvite, url: str) -> None: ...


class NullSender:
    """아무것도 보내지 않는다."""

    def send(self, invite: ExamInvite, url: str) -> None:
        return None
