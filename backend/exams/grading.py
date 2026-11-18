"""루브릭 채점기(#76). 키(`GRADER_ANTHROPIC_KEY`)가 있으면 Anthropic 채점기, 없으면 가짜 채점기.

채점기는 기록(`AIExchange`, 저장하지 않은 것도)을 받아 네 항목의 점수(0~5)와 근거 인용을 낸다. 근거 인용은
언제나 넘겨받은 기록의 `request`·`response` 안의 부분 문자열이다 — Anthropic 채점기가 낸 인용도 기록 안에
없으면 버린다.
"""

from __future__ import annotations

import json
import re
import urllib.request
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

from django.conf import settings

if TYPE_CHECKING:
    from .models import AIExchange

#: 루브릭 항목 — 이 순서로 보인다.
RUBRIC_KEYS = ("decomposition", "instruction_clarity", "verification", "risky_command_guard")
RUBRIC_LABELS = {
    "decomposition": "문제 나누기",
    "instruction_clarity": "지시 명확성",
    "verification": "결과 검증",
    "risky_command_guard": "위험 명령 막기",
}
MAX_SCORE = 5
#: 항목마다 남기는 근거 인용 수와 한 인용의 최대 길이.
MAX_EVIDENCE = 3
MAX_QUOTE_CHARS = 300


@dataclass(frozen=True)
class RubricItem:
    """루브릭 한 항목의 채점 결과. `key` 는 decomposition·instruction_clarity·verification·risky_command_guard,
    `score` 는 0~5, `evidence` 는 넘겨받은 기록의 요청·응답 원문 안의 부분 문자열."""

    key: str
    score: int
    evidence: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Turn:
    """대화 발화 하나 — 채점기의 공통 재료. `role` 은 "user" 또는 "assistant"."""

    role: str
    text: str


def turns_from_exchanges(exchanges: list[AIExchange]) -> list[Turn]:
    """프록시 기록 → 발화. 기록 순서대로 요청은 사용자, 응답은 AI 발화. 빈 글은 뺀다."""

    turns = []
    for ex in exchanges:
        if ex.request:
            turns.append(Turn("user", ex.request))
        if ex.response:
            turns.append(Turn("assistant", ex.response))
    return turns


def turns_from_transcript(ai_transcript: list[dict] | None) -> list[Turn]:
    """제출의 AI 대화 기록(도구마다 `entries`) → 저장된 순서 그대로의 발화. 빈 글은 뺀다."""

    turns = []
    for tool in ai_transcript or []:
        for entry in tool.get("entries") or []:
            text = entry.get("text")
            if text:
                turns.append(Turn(entry.get("role", ""), text))
    return turns


class Grader(Protocol):
    def grade(self, exchanges: list[AIExchange]) -> list[RubricItem]: ...

    def grade_turns(self, turns: list[Turn]) -> list[RubricItem]: ...


_SENTENCE = re.compile(r"[^\n.!?。]+[.!?。]?")


def _sentences(text: str) -> list[str]:
    """글을 문장으로 나눈다. 앞뒤 공백만 걷어 내므로 각 문장은 원문의 부분 문자열이다."""

    out = []
    for m in _SENTENCE.finditer(text or ""):
        s = m.group(0).strip()
        if s:
            out.append(s[:MAX_QUOTE_CHARS])
    return out


# 가짜 채점기의 항목별 단서. (요청에서만 찾을지, 단서)
_CUES: dict[str, tuple[bool, re.Pattern[str]]] = {
    "decomposition": (
        False,
        re.compile(r"먼저|그다음|그 다음|다음으로|마지막으로|단계|순서|나눠|\bfirst\b|\bthen\b|\bfinally\b|\bstep", re.I),
    ),
    "instruction_clarity": (
        False,
        re.compile(r"`|://|\b(aws|kubectl|terraform|docker|helm)\b|\.\w{2,5}\b|--\w|이름|정확히", re.I),
    ),
    "verification": (
        False,
        re.compile(r"확인|검증|테스트|\bverify|\btest|\bcheck|\bget-|\bdescribe\b|\bstatus\b", re.I),
    ),
    "risky_command_guard": (
        False,
        re.compile(r"rm -rf|위험|삭제|하지 ?마|쓰지 ?말|금지|--force|\bdon'?t\b|\bdo not\b|\bdestroy\b|\bdrop\b", re.I),
    ),
}


class FakeGrader:
    """결정적 가짜 채점기 — 같은 기록이면 같은 결과, 근거는 기록 안의 글을 그대로 인용한다.

    항목마다 단서가 든 문장을 기록 순서대로 모아, 찾은 수(최대 5)를 점수로, 앞의 몇 문장을 근거로 낸다.
    """

    name = "fake"

    def grade(self, exchanges: list[AIExchange]) -> list[RubricItem]:
        return self.grade_turns(turns_from_exchanges(exchanges))

    def grade_turns(self, turns: list[Turn]) -> list[RubricItem]:
        items = []
        for key in RUBRIC_KEYS:
            requests_only, cue = _CUES[key]
            found: list[str] = []
            for turn in turns:
                if requests_only and turn.role != "user":
                    continue
                for s in _sentences(turn.text):
                    if cue.search(s) and s not in found:
                        found.append(s)
            items.append(RubricItem(key=key, score=min(MAX_SCORE, len(found)), evidence=found[:MAX_EVIDENCE]))
        return items


GRADER_MODEL = "claude-sonnet-5-5"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
_PROMPT = """너는 인프라 실습 시험의 채점관이다. 아래는 지원자가 AI 도구와 나눈 대화 기록이다.
네 항목을 0~5 정수로 채점하라: decomposition(문제 나누기), instruction_clarity(지시 명확성),
verification(결과 검증), risky_command_guard(위험 명령 막기).
항목마다 근거로 기록 안의 문장을 글자 그대로 1~3개 인용하라.
JSON 하나만 답하라: {"items": [{"key": "...", "score": 0, "evidence": ["..."]}]}

기록:
"""


def _clamp(value: object) -> int:
    try:
        n = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0
    return max(0, min(MAX_SCORE, n))


class AnthropicGrader:
    """Anthropic Messages API 로 채점한다. 기록 밖의 인용은 버리고, 빠진 항목은 0점·근거 없음으로 채운다."""

    name = "anthropic"

    def __init__(self, api_key: str, model: str = GRADER_MODEL):
        self.api_key = api_key
        self.model = model

    def _ask(self, prompt: str) -> str:
        body = json.dumps(
            {"model": self.model, "max_tokens": 2000, "messages": [{"role": "user", "content": prompt}]}
        ).encode()
        req = urllib.request.Request(
            ANTHROPIC_URL,
            data=body,
            method="POST",
            headers={"x-api-key": self.api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=120) as res:  # noqa: S310 — 고정 https 주소
            data = json.loads(res.read())
        return "".join(part.get("text", "") for part in data.get("content", []) if part.get("type") == "text")

    def grade(self, exchanges: list[AIExchange]) -> list[RubricItem]:
        return self.grade_turns(turns_from_exchanges(exchanges))

    def grade_turns(self, turns: list[Turn]) -> list[RubricItem]:
        transcript = "\n\n".join(
            f"[{n}] {'요청' if t.role == 'user' else '응답'}:\n{t.text}" for n, t in enumerate(turns, 1)
        )
        text = self._ask(_PROMPT + transcript)
        match = re.search(r"\{.*\}", text, re.S)
        parsed = json.loads(match.group(0)) if match else {}
        by_key = {i.get("key"): i for i in parsed.get("items", []) if isinstance(i, dict)}
        sources = [t.text for t in turns if t.text]
        items = []
        for key in RUBRIC_KEYS:
            raw = by_key.get(key, {})
            quotes = [q.strip() for q in raw.get("evidence", []) if isinstance(q, str)]
            quotes = [q for q in quotes if q and any(q in s for s in sources)][:MAX_EVIDENCE]
            items.append(RubricItem(key=key, score=_clamp(raw.get("score")), evidence=quotes))
        return items


def get_grader() -> Grader:
    key = getattr(settings, "GRADER_ANTHROPIC_KEY", "")
    if key:
        return AnthropicGrader(key)
    return FakeGrader()
