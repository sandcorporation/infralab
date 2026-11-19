"""채점·연습 피드백의 Claude 사용량(#249) — 호출마다 `LLMUsage` 행 하나를 쌓는다.

Anthropic 채점기를 키로 켜고 `urllib.request.urlopen` 만 가짜 응답(usage 포함)으로 바꿔 네트워크 없이 본다.
보고서 채점은 담당자 API, 연습 피드백은 학생 API 를 부른다 — 바깥에서 보이는 요청과 쌓인 행만 본다.
"""

from __future__ import annotations

import io
import json

import pytest
from django.test import override_settings

from exams import grading
from exams.models import LLMUsage
from tests.test_spec_exam_report import SECRET, _grade, _path, _setup
from tests.test_spec_practice_feedback import _feedback, _practice_user, _submit

pytestmark = pytest.mark.django_db

USAGE = {
    "input_tokens": 1234,
    "output_tokens": 321,
    "cache_read_input_tokens": 50,
    "cache_creation_input_tokens": 7,
}
ANSWER = {"items": [{"key": "decomposition", "score": 3, "evidence": []}]}


class _Res(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


@pytest.fixture
def claude(monkeypatch):
    """가짜 Anthropic — 실제 API 처럼 `model`·`usage` 를 담아 답한다. 부른 횟수를 센다."""

    calls: list[dict[str, object]] = []

    def fake_urlopen(req, timeout=None):
        body = json.loads(req.data)
        calls.append(body)
        data = {
            "model": body["model"],
            "content": [{"type": "text", "text": json.dumps(ANSWER)}],
            "usage": USAGE,
        }
        return _Res(json.dumps(data).encode())

    monkeypatch.setattr(grading.urllib.request, "urlopen", fake_urlopen)
    with override_settings(EXAM_PROXY_SECRET=SECRET, GRADER_ANTHROPIC_KEY="sk-test"):
        yield calls


def _tokens(row: LLMUsage) -> dict[str, int]:
    return {
        "input_tokens": row.input_tokens,
        "output_tokens": row.output_tokens,
        "cache_read_input_tokens": row.cache_read_input_tokens,
        "cache_creation_input_tokens": row.cache_creation_input_tokens,
    }


def test_grading_once_stores_one_usage_row_with_the_response_tokens(api, claude):
    teacher, cohort, invite = _setup(api)

    _grade(api, teacher, cohort["id"], invite["id"])

    rows = list(LLMUsage.objects.all())
    assert len(claude) == 1 and len(rows) == 1
    row = rows[0]
    assert row.purpose == LLMUsage.PURPOSE_GRADING
    assert row.model == grading.GRADER_MODEL
    assert _tokens(row) == USAGE
    assert row.invite_id == invite["id"] and row.submission_id is None
    assert row.created_at is not None


def test_regrading_adds_rows_and_keeps_the_earlier_ones(api, claude):
    teacher, cohort, invite = _setup(api)

    _grade(api, teacher, cohort["id"], invite["id"])
    first = LLMUsage.objects.get()
    _grade(api, teacher, cohort["id"], invite["id"])

    assert LLMUsage.objects.filter(invite_id=invite["id"]).count() == 2
    assert LLMUsage.objects.filter(pk=first.pk).exists()


def test_practice_feedback_once_stores_one_usage_row(api, claude):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)

    res = _feedback(api, s, sub["id"])

    assert res.status_code == 200, res.content
    row = LLMUsage.objects.get()
    assert row.purpose == LLMUsage.PURPOSE_PRACTICE_FEEDBACK
    assert _tokens(row) == USAGE
    assert row.submission_id == sub["id"] and row.invite_id is None
    # 이미 있는 피드백을 다시 받으면 Claude 를 부르지 않으니 행도 없다.
    assert _feedback(api, s, sub["id"]).status_code == 200
    assert LLMUsage.objects.count() == 1


def test_usage_save_failure_does_not_break_grading_or_feedback(api, claude, monkeypatch):
    def broken(*args: object, **kwargs: object) -> None:
        raise RuntimeError("db down")

    monkeypatch.setattr(LLMUsage.objects, "create", broken)
    teacher, cohort, invite = _setup(api)

    report = _grade(api, teacher, cohort["id"], invite["id"])
    assert report["rubric"]["grader"] == "anthropic"

    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)
    res = _feedback(api, s, sub["id"])
    assert res.status_code == 200, res.content
    assert api.get(f"/api/practice/submissions/{sub['id']}/feedback", s).status_code == 200
    assert api.get(_path(cohort["id"], invite["id"]), teacher).json()["rubric"] is not None
    assert LLMUsage.objects.count() == 0


def test_fake_grader_stores_no_usage(api):
    with override_settings(EXAM_PROXY_SECRET=SECRET, GRADER_ANTHROPIC_KEY=""):
        teacher, cohort, invite = _setup(api)
        _grade(api, teacher, cohort["id"], invite["id"])

    assert LLMUsage.objects.count() == 0


def test_usage_from_response_without_usage_is_none_and_ignores_bad_values():
    assert grading.usage_from_response({"content": []}, "m") is None
    u = grading.usage_from_response({"usage": {"input_tokens": "x", "output_tokens": 5}}, "fallback")
    assert u == grading.Usage(model="fallback", input_tokens=0, output_tokens=5)
