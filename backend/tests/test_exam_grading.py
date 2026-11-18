"""루브릭 채점기(#76) — 저장하지 않은 기록, 빈 기록, Anthropic 채점기의 인용 거르기."""

import json

from django.test import override_settings

from exams.grading import RUBRIC_KEYS, AnthropicGrader, FakeGrader, get_grader
from exams.models import AIExchange


def _ex(request, response=""):
    return AIExchange(tool="claude_code", request=request, response=response)


def test_fake_grader_takes_unsaved_exchanges_and_quotes_them():
    exchanges = [_ex("먼저 버킷을 만들고 그다음 확인해 줘. rm -rf 는 쓰지 말고.", "검증했습니다.")]

    items = FakeGrader().grade(exchanges)

    assert [i.key for i in items] == list(RUBRIC_KEYS)
    for item in items:
        assert 0 <= item.score <= 5
        assert all(q in exchanges[0].request or q in exchanges[0].response for q in item.evidence)


def test_fake_grader_gives_zero_without_records():
    items = FakeGrader().grade([])

    assert [(i.score, i.evidence) for i in items] == [(0, [])] * 4


def test_get_grader_is_anthropic_with_a_key():
    with override_settings(GRADER_ANTHROPIC_KEY="sk-test"):
        assert isinstance(get_grader(), AnthropicGrader)


def test_anthropic_grader_drops_quotes_not_in_the_records_and_clamps(monkeypatch):
    grader = AnthropicGrader("sk-test")
    answer = {
        "items": [
            {"key": "decomposition", "score": 9, "evidence": ["먼저 버킷을 만들어", "지어낸 문장"]},
            {"key": "verification", "score": "2", "evidence": ["확인했습니다"]},
        ]
    }
    monkeypatch.setattr(grader, "_ask", lambda prompt: "결과:\n" + json.dumps(answer, ensure_ascii=False))

    items = {i.key: i for i in grader.grade([_ex("먼저 버킷을 만들어 줘.", "확인했습니다.")])}

    assert (items["decomposition"].score, items["decomposition"].evidence) == (5, ["먼저 버킷을 만들어"])
    assert (items["verification"].score, items["verification"].evidence) == (2, ["확인했습니다"])
    assert (items["risky_command_guard"].score, items["risky_command_guard"].evidence) == (0, [])
