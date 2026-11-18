"""채점기 입력 넓히기 — 「대화 발화 목록」을 받는 채점기와 시험 쪽 회귀 없음.

target: backend/tests/test_spec_practice_grader.py
AC: #131: 채점기는 발화 목록을 받아 루브릭 네 항목을 이 순서로, 0~5 정수 점수와 발화 글 안의 근거 인용으로 낸다(Anthropic 채점기의 발화 밖 인용은 버린다)
AC: #131: 프록시 기록은 요청 → 사용자 발화, 응답 → AI 발화로 바뀌고(빈 글은 빠진다), 옛 입력으로 채점한 결과와 같다
AC: #131: 제출의 AI 대화 기록은 저장된 순서 그대로 발화 목록이 된다

채점기(`exams.grading`)를 직접 부른다. 가짜 채점기는 결정적이라 옛 입력(`grade(exchanges)`)과 새 입력
(`grade_turns(turns)`)의 결과를 그대로 견준다. Anthropic 채점기는 `_ask` 를 바꿔 네트워크 없이 본다. 시험의 보고서·채점
흐름이 그대로인지는 기존 `test_exam_grading.py`·`test_spec_exam_report.py` 가 단언을 바꾸지 않고 본다.
"""

import json

import pytest

from exams.grading import (
    RUBRIC_KEYS,
    AnthropicGrader,
    FakeGrader,
    Turn,
    turns_from_exchanges,
    turns_from_transcript,
)
from exams.models import AIExchange

EXCHANGES = [
    AIExchange(
        tool="claude_code",
        request="먼저 버킷을 만들고, 그다음 버저닝을 켜 줘. rm -rf 는 쓰지 마.",
        response="aws s3 mb s3://lab-site 를 실행했습니다. 결과를 확인했습니다.",
    ),
    AIExchange(tool="claude_code", request="aws s3api get-bucket-versioning 으로 검증해 줘.", response=""),
]

TRANSCRIPT = [
    {
        "tool": "claude",
        "since": "2026-11-18T01:00:00Z",
        "truncated": False,
        "entries": [
            {"role": "user", "at": "2026-11-18T01:00:01Z", "text": "먼저 index.html 을 올리고 그다음 웹사이트 설정을 켜 줘."},
            {"role": "assistant", "at": "2026-11-18T01:00:05Z", "text": "업로드했습니다. curl 로 확인했습니다."},
        ],
    },
    {
        "tool": "codex",
        "since": "2026-11-18T01:10:00Z",
        "truncated": False,
        "entries": [
            {"role": "user", "at": "2026-11-18T01:10:01Z", "text": "버킷을 삭제하지 말고 정책만 고쳐 줘."},
            {"role": "assistant", "at": "2026-11-18T01:10:04Z", "text": ""},
        ],
    },
]


@pytest.mark.skip(reason="#131")
def test_proxy_records_become_user_and_assistant_turns_in_order():
    assert turns_from_exchanges(EXCHANGES) == [
        Turn("user", EXCHANGES[0].request),
        Turn("assistant", EXCHANGES[0].response),
        Turn("user", EXCHANGES[1].request),
    ]


@pytest.mark.skip(reason="#131")
def test_a_submission_transcript_becomes_turns_in_stored_order():
    assert turns_from_transcript(TRANSCRIPT) == [
        Turn("user", "먼저 index.html 을 올리고 그다음 웹사이트 설정을 켜 줘."),
        Turn("assistant", "업로드했습니다. curl 로 확인했습니다."),
        Turn("user", "버킷을 삭제하지 말고 정책만 고쳐 줘."),
    ]
    assert turns_from_transcript(None) == []
    assert turns_from_transcript([]) == []


@pytest.mark.skip(reason="#131")
def test_fake_grader_gives_the_same_result_for_records_and_their_turns():
    old = FakeGrader().grade(EXCHANGES)
    new = FakeGrader().grade_turns(turns_from_exchanges(EXCHANGES))

    assert new == old
    assert [i.key for i in new] == list(RUBRIC_KEYS)


@pytest.mark.skip(reason="#131")
def test_fake_grader_grades_turns_with_quotes_from_their_text():
    turns = turns_from_transcript(TRANSCRIPT)

    items = FakeGrader().grade_turns(turns)

    assert [i.key for i in items] == list(RUBRIC_KEYS)
    texts = [t.text for t in turns]
    for item in items:
        assert isinstance(item.score, int) and 0 <= item.score <= 5
        assert all(any(q in t for t in texts) for q in item.evidence)
    # 같은 발화면 같은 결과(결정적).
    assert FakeGrader().grade_turns(turns) == items
    # 단서가 든 발화에서는 점수가 0 이 아니다 — 「먼저 … 그다음」, 「확인」, 「삭제하지 말고」.
    by_key = {i.key: i for i in items}
    assert by_key["decomposition"].score > 0 and by_key["decomposition"].evidence
    assert by_key["verification"].score > 0 and by_key["verification"].evidence
    assert by_key["risky_command_guard"].score > 0 and by_key["risky_command_guard"].evidence


@pytest.mark.skip(reason="#131")
def test_fake_grader_gives_zero_without_turns():
    items = FakeGrader().grade_turns([])

    assert [(i.key, i.score, i.evidence) for i in items] == [(k, 0, []) for k in RUBRIC_KEYS]


@pytest.mark.skip(reason="#131")
def test_anthropic_grader_drops_quotes_outside_the_turns_and_clamps(monkeypatch):
    grader = AnthropicGrader("sk-test")
    answer = {
        "items": [
            {"key": "decomposition", "score": 7, "evidence": ["먼저 index.html 을 올리고", "지어낸 문장"]},
            {"key": "verification", "score": "3", "evidence": ["curl 로 확인했습니다"]},
            {"key": "risky_command_guard", "score": -2, "evidence": ["버킷을 삭제하지 말고"]},
        ]
    }
    asked: list[str] = []

    def fake_ask(prompt):
        asked.append(prompt)
        return "채점:\n" + json.dumps(answer, ensure_ascii=False)

    monkeypatch.setattr(grader, "_ask", fake_ask)

    items = {i.key: i for i in grader.grade_turns(turns_from_transcript(TRANSCRIPT))}

    assert list(items) == list(RUBRIC_KEYS)
    assert (items["decomposition"].score, items["decomposition"].evidence) == (5, ["먼저 index.html 을 올리고"])
    assert (items["verification"].score, items["verification"].evidence) == (3, ["curl 로 확인했습니다"])
    assert (items["risky_command_guard"].score, items["risky_command_guard"].evidence) == (0, ["버킷을 삭제하지 말고"])
    assert (items["instruction_clarity"].score, items["instruction_clarity"].evidence) == (0, [])
    # 채점기에게 보낸 글에 발화가 들어 있다.
    assert len(asked) == 1 and "버킷을 삭제하지 말고 정책만 고쳐 줘." in asked[0]
