"""루브릭 채점기(#76). 키(`GRADER_ANTHROPIC_KEY`)가 있으면 Anthropic 채점기, 없으면 가짜 채점기."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from .models import AIExchange


@dataclass(frozen=True)
class RubricItem:
    """루브릭 한 항목의 채점 결과. `key` 는 decomposition·instruction_clarity·verification·risky_command_guard,
    `score` 는 0~5, `evidence` 는 넘겨받은 기록의 요청·응답 원문 안의 부분 문자열."""

    key: str
    score: int
    evidence: list[str] = field(default_factory=list)


class Grader(Protocol):
    def grade(self, exchanges: list[AIExchange]) -> list[RubricItem]: ...


class FakeGrader:
    """결정적 가짜 채점기 — 같은 기록이면 같은 결과, 근거는 기록 안의 글을 그대로 인용한다."""

    def grade(self, exchanges: list[AIExchange]) -> list[RubricItem]:
        raise NotImplementedError("#76")


def get_grader() -> Grader:
    raise NotImplementedError("#76")
