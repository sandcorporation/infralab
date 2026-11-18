"""연습 피드백 — 「피드백 받기」(제출당 하나·하루 5회·실패 미산정·Asia/Seoul 날짜)와 남은 횟수.

target: backend/tests/test_spec_practice_feedback.py
AC: #134: POST …/feedback 이 내 연습 제출의 대화 기록을 채점해 네 항목(이 순서, 0~5, 한글 이름, 그 제출의 대화 기록 안의 근거)을 저장하고 돌려준다
AC: #134: 같은 제출에 다시 요청하면 기존 피드백을 돌려주고 횟수가 줄지 않는다. GET …/feedback 은 있으면 그것, 없으면 404
AC: #134: 대화 기록이 없는 제출은 422 이고 횟수를 쓰지 않는다
AC: #134: 6번째 새 피드백 요청은 429 와 「오늘 피드백 5회를 다 썼습니다 — 내일 다시」, 날짜는 Asia/Seoul 기준
AC: #134: 채점기가 실패하면 502 이고 세지 않는다
AC: #134: GET /api/practice/feedback-quota 는 {limit: 5, used, remaining}
AC: #134: 다른 사용자의 제출, 연습이 아닌 묶음의 제출은 404

연습 참여(`/api/practice/join`, #132)로 들어가 기존 제출 경로로 대화 기록을 붙여 낸 뒤 피드백 API 를 부른다. 채점 키는
비워 가짜 채점기만 쓰고, 채점 실패는 키를 넣고 `AnthropicGrader._ask` 를 실패시켜 만든다(네트워크 없음). 「오늘」은
`django.utils.timezone.now` 를 고정한 시각으로 바꿔 본다 — 로그인은 바꾸기 전에 한다.
"""

from datetime import datetime, timezone as dt_timezone

import pytest
from django.test import override_settings

from exams import grading
from tests.api_helpers import S3, S3_CHECK_IDS, s3_results

pytestmark = [pytest.mark.django_db, pytest.mark.usefixtures("fake_grader")]

LIMIT_MESSAGE = "오늘 피드백 5회를 다 썼습니다 — 내일 다시"
RUBRIC_KEYS = ["decomposition", "instruction_clarity", "verification", "risky_command_guard"]
RUBRIC_LABELS = ["문제 나누기", "지시 명확성", "결과 검증", "위험 명령 막기"]
USER_TEXT = "먼저 버킷을 만들고 그다음 버저닝을 켜 줘. rm -rf 같은 위험한 명령은 쓰지 마."
AI_TEXT = "aws s3 mb s3://lab-site 를 실행했습니다. get-bucket-versioning 으로 결과를 확인했습니다."


def _transcript(user_text=USER_TEXT, ai_text=AI_TEXT):
    return [
        {
            "tool": "claude",
            "since": "2026-01-10T00:00:00Z",
            "truncated": False,
            "entries": [
                {"role": "user", "at": "2026-01-10T00:00:01Z", "text": user_text},
                {"role": "assistant", "at": "2026-01-10T00:00:05Z", "text": ai_text},
            ],
        }
    ]


@pytest.fixture
def fake_grader():
    with override_settings(GRADER_ANTHROPIC_KEY=""):
        yield


def _practice_user(api, uid="p1"):
    s = api.login(uid)
    res = api.post("/api/practice/join", session=s)
    assert res.status_code == 200, res.content
    return s, res.json()["cohort_id"]


def _submit(api, s, cohort_id, transcript="default"):
    body = {"agent_version": "0.9.0", "results": s3_results({"bucket-exists"})}
    if transcript == "default":
        body["ai_transcript"] = _transcript()
    elif transcript is not None:
        body["ai_transcript"] = transcript
    res = api.post(f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions", body, s)
    assert res.status_code == 201, res.content
    return res.json()


def _feedback(api, s, sub_id):
    return api.post(f"/api/practice/submissions/{sub_id}/feedback", session=s)


def _quota(api, s):
    res = api.get("/api/practice/feedback-quota", s)
    assert res.status_code == 200, res.content
    return res.json()


def _at(monkeypatch, year, month, day, hour, minute):
    fixed = datetime(year, month, day, hour, minute, tzinfo=dt_timezone.utc)
    monkeypatch.setattr("django.utils.timezone.now", lambda: fixed)


@pytest.mark.skip(reason="#134")
def test_feedback_grades_the_submission_transcript_and_stores_it(api):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)

    res = _feedback(api, s, sub["id"])

    assert res.status_code == 200, res.content
    body = res.json()
    assert body["submission_id"] == sub["id"]
    assert body["grader"] == "fake"
    assert body["graded_at"]
    assert [i["key"] for i in body["items"]] == RUBRIC_KEYS
    assert [i["label"] for i in body["items"]] == RUBRIC_LABELS
    for item in body["items"]:
        assert isinstance(item["score"], int) and 0 <= item["score"] <= 5
        assert all(q in USER_TEXT or q in AI_TEXT for q in item["evidence"])
    # 단서가 든 대화 — 가짜 채점기가 근거를 찾는다.
    assert any(i["evidence"] for i in body["items"])

    stored = api.get(f"/api/practice/submissions/{sub['id']}/feedback", s)
    assert stored.status_code == 200
    assert stored.json() == body


@pytest.mark.skip(reason="#134")
def test_get_feedback_is_404_before_asking(api):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)

    assert api.get(f"/api/practice/submissions/{sub['id']}/feedback", s).status_code == 404


@pytest.mark.skip(reason="#134")
def test_same_submission_again_returns_the_existing_feedback_without_using_the_quota(api):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)
    first = _feedback(api, s, sub["id"]).json()
    assert _quota(api, s) == {"limit": 5, "used": 1, "remaining": 4}

    again = _feedback(api, s, sub["id"])

    assert again.status_code == 200
    assert again.json() == first
    assert _quota(api, s) == {"limit": 5, "used": 1, "remaining": 4}


@pytest.mark.skip(reason="#134")
def test_submission_without_a_transcript_is_refused_and_not_counted(api):
    s, pid = _practice_user(api)
    plain = _submit(api, s, pid, transcript=None)
    empty = _submit(api, s, pid, transcript=[{**_transcript()[0], "entries": []}])

    assert _feedback(api, s, plain["id"]).status_code == 422
    assert _feedback(api, s, empty["id"]).status_code == 422
    assert _quota(api, s) == {"limit": 5, "used": 0, "remaining": 5}
    assert api.get(f"/api/practice/submissions/{plain['id']}/feedback", s).status_code == 404


@pytest.mark.skip(reason="#134")
def test_sixth_feedback_of_the_day_is_429(api, monkeypatch):
    s, pid = _practice_user(api)
    _at(monkeypatch, 2026, 1, 10, 3, 0)  # 한국 2026-01-10 12:00
    subs = [_submit(api, s, pid) for _ in range(6)]

    for n, sub in enumerate(subs[:5], start=1):
        res = _feedback(api, s, sub["id"])
        assert res.status_code == 200, res.content
        assert _quota(api, s)["remaining"] == 5 - n

    sixth = _feedback(api, s, subs[5]["id"])
    assert sixth.status_code == 429
    assert sixth.json()["detail"] == LIMIT_MESSAGE
    assert _quota(api, s) == {"limit": 5, "used": 5, "remaining": 0}
    assert api.get(f"/api/practice/submissions/{subs[5]['id']}/feedback", s).status_code == 404
    # 이미 받은 피드백은 한도를 다 써도 다시 볼 수 있다.
    assert _feedback(api, s, subs[0]["id"]).status_code == 200


@pytest.mark.skip(reason="#134")
def test_the_day_turns_at_midnight_in_seoul_not_utc(api, monkeypatch):
    s, pid = _practice_user(api)
    _at(monkeypatch, 2026, 1, 10, 15, 0)  # 한국 2026-01-11 00:00
    subs = [_submit(api, s, pid) for _ in range(7)]
    for sub in subs[:5]:
        assert _feedback(api, s, sub["id"]).status_code == 200

    # UTC 로는 다음 날이지만 한국으로는 아직 같은 날(2026-01-11 23:59).
    _at(monkeypatch, 2026, 1, 11, 14, 59)
    assert _feedback(api, s, subs[5]["id"]).status_code == 429
    assert _quota(api, s)["remaining"] == 0

    # 한국 자정(2026-01-12 00:00)이 지나면 다시 5회.
    _at(monkeypatch, 2026, 1, 11, 15, 0)
    assert _quota(api, s) == {"limit": 5, "used": 0, "remaining": 5}
    assert _feedback(api, s, subs[5]["id"]).status_code == 200
    assert _quota(api, s)["remaining"] == 4


@pytest.mark.skip(reason="#134")
def test_quota_is_per_user(api):
    a, pid = _practice_user(api, "pa")
    b, _ = _practice_user(api, "pb")
    for _ in range(2):
        assert _feedback(api, a, _submit(api, a, pid)["id"]).status_code == 200

    assert _quota(api, a)["remaining"] == 3
    assert _quota(api, b) == {"limit": 5, "used": 0, "remaining": 5}


@pytest.mark.skip(reason="#134")
def test_failed_grading_is_502_and_not_counted(api, monkeypatch):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid)

    def broken(self, prompt):
        raise OSError("grader down")

    monkeypatch.setattr(grading.AnthropicGrader, "_ask", broken)
    with override_settings(GRADER_ANTHROPIC_KEY="sk-test"):
        res = _feedback(api, s, sub["id"])

    assert res.status_code == 502
    assert _quota(api, s) == {"limit": 5, "used": 0, "remaining": 5}
    assert api.get(f"/api/practice/submissions/{sub['id']}/feedback", s).status_code == 404
    # 다시 누르면(채점기가 살아나면) 받는다.
    assert _feedback(api, s, sub["id"]).status_code == 200
    assert _quota(api, s)["remaining"] == 4


@pytest.mark.skip(reason="#134")
def test_other_users_submission_is_404(api):
    a, pid = _practice_user(api, "pa")
    b, _ = _practice_user(api, "pb")
    sub = _submit(api, a, pid)
    assert _feedback(api, a, sub["id"]).status_code == 200

    assert _feedback(api, b, sub["id"]).status_code == 404
    assert api.get(f"/api/practice/submissions/{sub['id']}/feedback", b).status_code == 404
    assert _quota(api, b)["used"] == 0


@pytest.mark.skip(reason="#134")
def test_class_cohort_submission_gets_no_practice_feedback(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기")
    api.open_scenarios(teacher, cohort["id"], [S3])
    s, _ = _practice_user(api)
    api.join(s, cohort["join_token"])
    res = api.post(
        f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions",
        {"agent_version": "0.9.0", "results": s3_results(set(S3_CHECK_IDS)), "ai_transcript": _transcript()},
        s,
    )
    assert res.status_code == 201, res.content

    assert _feedback(api, s, res.json()["id"]).status_code == 404
    assert _quota(api, s)["used"] == 0


@pytest.mark.skip(reason="#134")
def test_feedback_needs_login(api):
    assert api.get("/api/practice/feedback-quota").status_code == 401
    assert api.post("/api/practice/submissions/1/feedback").status_code == 401
