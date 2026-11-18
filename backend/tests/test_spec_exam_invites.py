"""시험 회차 설정과 응시 링크 — 저장·검증·조직 경계, 링크 발급·목록·회수, 보내지 않는 발송기.

target: backend/tests/test_spec_exam_invites.py
AC: #70: PUT exam-settings 로 시험 회차 설정을 저장하고 기수 응답의 exam_settings 에 정규화된 값이 보인다
AC: #70: 수업 묶음에 시험 설정을 넣으면 422, 남의 조직 묶음이면 404
AC: #70: claude_code·codex 를 허용하고 모델을 비우면 422, 시간 제한 1..600 밖 422, 도구는 비어도 되고 한도는 0 이상, 잘못된 설정은 저장되지 않는다
AC: #70: 시험 설정을 저장하기 전에는 응시 링크를 발급할 수 없다(409)
AC: #70: 응시 링크 발급(201)·목록·회수(204), 상태 invited → revoked. 수업 묶음 422, 남의 조직 404
AC: #70: 발송기 인터페이스(보내지 않는 기본 구현)가 있고 SMTP 설정은 없다

조직 담당자가 강사 API(`/api/instructor/cohorts/{id}/exam-settings`, `…/exam-invites`)를 테스트 클라이언트로
부른다. 응시 링크 주소(웹)는 web/src/spec/spec_exam_invites.test.ts 가 본다.
"""

from pathlib import Path

import pytest
from django.core import mail

from tests.api_helpers import S3

pytestmark = pytest.mark.django_db

SETTINGS_FILE = Path(__file__).resolve().parent.parent / "config" / "settings.py"

EXAM_SETTINGS = {
    "time_limit_minutes": 90,
    "tools": ["claude_code", "codex"],
    "models": {"claude_code": "claude-sonnet-4-5", "codex": "gpt-5-codex"},
    "proctoring": True,
    "hidden_checks": True,
    "ai_token_limit": 200000,
}


def _exam_cohort(api, teacher, name="1회차"):
    res = api.post("/api/instructor/cohorts", {"name": name, "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    return res.json()


def _put_settings(api, teacher, cohort_id, body):
    return api.put(f"/api/instructor/cohorts/{cohort_id}/exam-settings", body, teacher)


def _invites_path(cohort_id):
    return f"/api/instructor/cohorts/{cohort_id}/exam-invites"


def test_exam_settings_are_saved_and_shown_on_the_cohort(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)

    res = _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS)

    assert res.status_code == 200, res.content
    assert res.json()["id"] == cohort["id"]
    assert res.json()["exam_settings"] == EXAM_SETTINGS
    again = api.get(f"/api/instructor/cohorts/{cohort['id']}", teacher).json()
    assert again["exam_settings"] == EXAM_SETTINGS


def test_models_of_tools_that_are_not_allowed_are_dropped(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)
    body = {**EXAM_SETTINGS, "tools": ["claude_code", "local_llm"], "models": {"claude_code": "m1", "codex": "m2"}}

    res = _put_settings(api, teacher, cohort["id"], body)

    assert res.status_code == 200, res.content
    saved = res.json()["exam_settings"]
    assert saved["tools"] == ["claude_code", "local_llm"]
    assert saved["models"] == {"claude_code": "m1"}


def test_exam_without_ai_tools_is_allowed(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)

    res = _put_settings(api, teacher, cohort["id"], {**EXAM_SETTINGS, "tools": [], "models": {}, "ai_token_limit": 0})

    assert res.status_code == 200, res.content
    saved = res.json()["exam_settings"]
    assert saved["tools"] == [] and saved["models"] == {} and saved["ai_token_limit"] == 0


def test_exam_settings_on_a_class_cohort_is_422_and_on_another_org_is_404(api):
    teacher = api.login_instructor()
    klass = api.create_cohort(teacher, "수업 1기")
    assert _put_settings(api, teacher, klass["id"], EXAM_SETTINGS).status_code == 422
    assert api.get(f"/api/instructor/cohorts/{klass['id']}", teacher).json()["exam_settings"] == {}

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert _put_settings(api, outsider, _exam_cohort(api, teacher)["id"], EXAM_SETTINGS).status_code == 404


@pytest.mark.parametrize(
    "change",
    [
        {"models": {"codex": "gpt-5-codex"}},  # claude_code 의 모델이 없다
        {"models": {"claude_code": "", "codex": "gpt-5-codex"}},  # claude_code 의 모델이 비었다
        {"models": {"claude_code": "claude-sonnet-4-5", "codex": "  "}},  # codex 의 모델이 공백
        {"time_limit_minutes": 0},
        {"time_limit_minutes": 601},
        {"ai_token_limit": -1},
        {"tools": ["claude_code", "cursor"]},  # 모르는 도구
    ],
    ids=["claude-model-missing", "claude-model-empty", "codex-model-blank", "time-0", "time-601", "limit-negative", "unknown-tool"],
)
def test_invalid_exam_settings_are_422_and_not_saved(api, change):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)
    assert _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS).status_code == 200

    res = _put_settings(api, teacher, cohort["id"], {**EXAM_SETTINGS, **change})

    assert res.status_code == 422, res.content
    assert api.get(f"/api/instructor/cohorts/{cohort['id']}", teacher).json()["exam_settings"] == EXAM_SETTINGS


def test_time_limit_bounds_are_inclusive(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)
    for minutes in (1, 600):
        res = _put_settings(api, teacher, cohort["id"], {**EXAM_SETTINGS, "time_limit_minutes": minutes})
        assert res.status_code == 200, res.content
        assert res.json()["exam_settings"]["time_limit_minutes"] == minutes


def test_invite_before_exam_settings_is_409(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)

    res = api.post(_invites_path(cohort["id"]), {"label": "지원자 A"}, teacher)

    assert res.status_code == 409
    assert api.get(_invites_path(cohort["id"]), teacher).json() == []


def test_invites_are_issued_listed_and_revoked(api):
    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)
    _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS)
    api.open_scenarios(teacher, cohort["id"], [S3])

    first = api.post(_invites_path(cohort["id"]), {"label": "지원자 A"}, teacher)
    second = api.post(_invites_path(cohort["id"]), {"label": "지원자 B"}, teacher)

    assert first.status_code == 201 and second.status_code == 201, (first.content, second.content)
    a, b = first.json(), second.json()
    assert a["label"] == "지원자 A" and a["status"] == "invited"
    assert a["started_at"] is None and a["finished_at"] is None and a["created_at"]
    assert a["token"] and b["token"] and a["token"] != b["token"]
    assert a["token"] != cohort["join_token"]

    listed = api.get(_invites_path(cohort["id"]), teacher)
    assert listed.status_code == 200
    assert [(i["id"], i["label"], i["status"]) for i in listed.json()] == [
        (a["id"], "지원자 A", "invited"),
        (b["id"], "지원자 B", "invited"),
    ]

    res = api.delete(f"{_invites_path(cohort['id'])}/{a['id']}", teacher)
    assert res.status_code == 204
    assert res.content == b""
    statuses = {i["id"]: i["status"] for i in api.get(_invites_path(cohort["id"]), teacher).json()}
    assert statuses == {a["id"]: "revoked", b["id"]: "invited"}


def test_invites_on_a_class_cohort_are_422_and_on_another_org_are_404(api):
    teacher = api.login_instructor()
    klass = api.create_cohort(teacher, "수업 1기")
    assert api.post(_invites_path(klass["id"]), {"label": "A"}, teacher).status_code == 422

    exam = _exam_cohort(api, teacher)
    _put_settings(api, teacher, exam["id"], EXAM_SETTINGS)
    invite = api.post(_invites_path(exam["id"]), {"label": "A"}, teacher).json()

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert api.post(_invites_path(exam["id"]), {"label": "B"}, outsider).status_code == 404
    assert api.get(_invites_path(exam["id"]), outsider).status_code == 404
    assert api.delete(f"{_invites_path(exam['id'])}/{invite['id']}", outsider).status_code == 404
    # 내 다른 회차의 경로로는 그 링크를 회수할 수 없다.
    other_exam = _exam_cohort(api, teacher, "2회차")
    assert api.delete(f"{_invites_path(other_exam['id'])}/{invite['id']}", teacher).status_code == 404
    assert [i["status"] for i in api.get(_invites_path(exam["id"]), teacher).json()] == ["invited"]


def test_null_sender_sends_nothing_and_there_is_no_smtp_setting(api):
    from exams.models import ExamInvite
    from exams.senders import InviteSender, NullSender

    teacher = api.login_instructor()
    cohort = _exam_cohort(api, teacher)
    _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS)
    issued = api.post(_invites_path(cohort["id"]), {"label": "지원자 A"}, teacher).json()

    sender: InviteSender = NullSender()
    invite = ExamInvite.objects.get(pk=issued["id"])
    assert sender.send(invite, f"https://infralab.test/exam/{invite.token}") is None
    assert mail.outbox == []

    source = SETTINGS_FILE.read_text(encoding="utf-8")
    assert "SMTP" not in source and "EMAIL_" not in source
