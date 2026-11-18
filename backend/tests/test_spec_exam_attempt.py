"""지원자 응시 흐름 — 응시 링크 → enter(숨은 사용자 세션) → 동의·시작 → 남은 시간 → 마감.

target: backend/tests/test_spec_exam_attempt.py
AC: #71: GET /api/exam/{token}(로그인 없음)이 회차 이름·시간 제한·허용 도구·감독 여부·상태를 준다. 없거나 회수된 토큰 404
AC: #71: POST enter 가 응시 세션을 열고 응시자(참여)를 만든다. 다시 부르면 같은 사용자·같은 참여, 회수된 토큰 404
AC: #71: POST start 는 동의가 없으면 422, enter 전 409. 시작하면 in_progress·deadline·remaining_seconds, 두 번 눌러도 started_at 그대로
AC: #71: 시작 전에는 응시 세션으로 시나리오 상세·제출이 403, 시작 뒤에는 된다
AC: #71: 시간이 지나면 finished·remaining_seconds 0·제출 403. finish 도 즉시 마감(시작 전이면 409)
AC: #71: 마감 뒤 다시 start 하면 409
AC: #71: 담당자의 응시 링크 목록 상태가 in_progress·finished 로 바뀐다
AC: #71: 수업 묶음 학생의 시나리오·제출 흐름은 그대로다

지원자는 로그인하지 않은 새 테스트 클라이언트다(브라우저 하나). 「시간이 지났다」는 `ExamInvite.started_at` 을
시간 제한보다 앞으로 옮겨 만든다 — 서버 시각 기준 판정을 본다. 남은 시간의 화면 표시는
web/src/spec/spec_exam_attempt.test.ts 가 본다.
"""

from datetime import datetime, timedelta

import pytest
from django.test import Client
from django.utils import timezone

from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

pytestmark = pytest.mark.django_db

EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": True,
    "hidden_checks": False,
    "ai_token_limit": 100000,
}


def _exam(api, teacher, settings=EXAM_SETTINGS):
    res = api.post("/api/instructor/cohorts", {"name": "백엔드 1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    cohort = res.json()
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", settings, teacher)
    assert res.status_code == 200, res.content
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort


def _invite(api, teacher, cohort_id, label="지원자 A"):
    res = api.post(f"/api/instructor/cohorts/{cohort_id}/exam-invites", {"label": label}, teacher)
    assert res.status_code == 201, res.content
    return res.json()


def _browser() -> Session:
    return Session(client=Client(), username="")


def _enter(api, cand, token):
    res = api.post(f"/api/exam/{token}/enter", session=cand)
    assert res.status_code == 200, res.content
    return res.json()


def _start(api, cand, token):
    res = api.post(f"/api/exam/{token}/start", {"consent": True}, cand)
    assert res.status_code == 200, res.content
    return res.json()


def _setup(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    return teacher, cohort, invite


def _expire(invite_id, minutes_ago=61):
    from exams.models import ExamInvite

    ExamInvite.objects.filter(pk=invite_id).update(started_at=timezone.now() - timedelta(minutes=minutes_ago))


def _ts(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def _statuses(api, teacher, cohort_id):
    return {i["id"]: i["status"] for i in api.get(f"/api/instructor/cohorts/{cohort_id}/exam-invites", teacher).json()}


def test_exam_status_is_public_and_describes_the_exam(api):
    teacher, cohort, invite = _setup(api)

    res = _browser().client.get(f"/api/exam/{invite['token']}")

    assert res.status_code == 200, res.content
    body = res.json()
    assert body["cohort_id"] == cohort["id"]
    assert body["cohort_name"] == "백엔드 1회차"
    assert body["status"] == "invited"
    assert body["time_limit_minutes"] == 60
    assert body["tools"] == ["claude_code"]
    assert body["proctoring"] is True
    assert body["started_at"] is None and body["deadline"] is None and body["remaining_seconds"] is None
    assert abs((_ts(body["server_time"]) - timezone.now()).total_seconds()) < 60


def test_unknown_or_revoked_exam_link_is_404(api):
    teacher, cohort, invite = _setup(api)
    assert api.get("/api/exam/no-such-token").status_code == 404

    assert api.delete(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}", teacher).status_code == 204

    assert api.get(f"/api/exam/{invite['token']}").status_code == 404
    assert api.post(f"/api/exam/{invite['token']}/enter", session=_browser()).status_code == 404


def test_enter_opens_a_session_for_one_hidden_candidate(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()

    body = _enter(api, cand, invite["token"])

    assert body["status"] == "invited"
    me = api.me(cand)
    people = api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher).json()
    assert [(p["user_id"], p["display_name"]) for p in people] == [(me["id"], "지원자 A")]

    # 같은 브라우저로 다시, 그리고 브라우저를 껐다 켠 것처럼 새 클라이언트로 다시 열어도 같은 응시다.
    _enter(api, cand, invite["token"])
    again = _browser()
    _enter(api, again, invite["token"])
    assert api.me(again)["id"] == me["id"]
    people = api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher).json()
    assert [p["membership_id"] for p in people] == [people[0]["membership_id"]]

    # 다른 링크는 다른 지원자다.
    other = _invite(api, teacher, cohort["id"], "지원자 B")
    stranger = _browser()
    _enter(api, stranger, other["token"])
    assert api.me(stranger)["id"] != me["id"]


def test_start_needs_consent_and_enter(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()

    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 409

    _enter(api, cand, invite["token"])
    assert api.post(f"/api/exam/{invite['token']}/start", {}, cand).status_code == 422
    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": False}, cand).status_code == 422
    assert cand.client.get(f"/api/exam/{invite['token']}").json()["status"] == "invited"


def test_start_sets_the_deadline_once(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])

    body = _start(api, cand, invite["token"])

    assert body["status"] == "in_progress"
    started, deadline = _ts(body["started_at"]), _ts(body["deadline"])
    assert deadline - started == timedelta(minutes=60)
    assert 0 < body["remaining_seconds"] <= 60 * 60
    assert abs((started - timezone.now()).total_seconds()) < 60

    again = _start(api, cand, invite["token"])
    assert again["started_at"] == body["started_at"] and again["deadline"] == body["deadline"]
    status = cand.client.get(f"/api/exam/{invite['token']}").json()
    assert status["status"] == "in_progress" and status["started_at"] == body["started_at"]


def test_scenarios_and_submissions_open_only_after_start(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    base = f"/api/cohorts/{cohort['id']}/scenarios"

    assert api.get(base, cand).status_code == 403
    assert api.get(f"{base}/{S3}", cand).status_code == 403
    assert api.get(f"{base}/{S3}/prepare", cand).status_code == 403
    assert api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS))).status_code == 403

    _start(api, cand, invite["token"])

    assert api.get(base, cand).status_code == 200
    detail = api.get(f"{base}/{S3}", cand)
    assert detail.status_code == 200 and [c["id"] for c in detail.json()["checks"]] == S3_CHECK_IDS
    assert api.get(f"{base}/{S3}/prepare", cand).status_code == 200
    res = api.submit(cand, cohort["id"], S3, s3_results({"bucket-exists"}))
    assert res.status_code == 201, res.content
    assert res.json()["passed"] == 1


def test_time_running_out_finishes_the_attempt(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    _start(api, cand, invite["token"])

    _expire(invite["id"])

    status = cand.client.get(f"/api/exam/{invite['token']}").json()
    assert status["status"] == "finished"
    assert status["remaining_seconds"] == 0
    assert api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS))).status_code == 403


def test_finish_closes_at_once_and_needs_a_start(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 409

    _start(api, cand, invite["token"])
    res = api.post(f"/api/exam/{invite['token']}/finish", session=cand)

    assert res.status_code == 200, res.content
    assert res.json()["status"] == "finished"
    assert res.json()["remaining_seconds"] == 0
    assert api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS))).status_code == 403


@pytest.mark.parametrize("how", ["finish", "timeout"])
def test_start_after_the_end_is_409(api, how):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    started = _start(api, cand, invite["token"])
    if how == "finish":
        api.post(f"/api/exam/{invite['token']}/finish", session=cand)
    else:
        _expire(invite["id"])
    before = cand.client.get(f"/api/exam/{invite['token']}").json()

    res = api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand)

    assert res.status_code == 409
    after = cand.client.get(f"/api/exam/{invite['token']}").json()
    assert after["status"] == "finished"
    assert after["started_at"] == before["started_at"]
    if how == "finish":
        assert after["started_at"] == started["started_at"]


def test_instructor_invite_list_follows_the_attempt(api):
    teacher, cohort, invite = _setup(api)
    waiting = _invite(api, teacher, cohort["id"], "지원자 B")
    cand = _browser()
    _enter(api, cand, invite["token"])
    assert _statuses(api, teacher, cohort["id"]) == {invite["id"]: "invited", waiting["id"]: "invited"}

    _start(api, cand, invite["token"])
    assert _statuses(api, teacher, cohort["id"]) == {invite["id"]: "in_progress", waiting["id"]: "invited"}
    row = next(i for i in api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", teacher).json() if i["id"] == invite["id"])
    assert row["started_at"] is not None and row["finished_at"] is None

    api.post(f"/api/exam/{invite['token']}/finish", session=cand)
    assert _statuses(api, teacher, cohort["id"]) == {invite["id"]: "finished", waiting["id"]: "invited"}
    row = next(i for i in api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", teacher).json() if i["id"] == invite["id"])
    assert row["finished_at"] is not None


def test_class_cohort_students_keep_the_old_flow(api):
    teacher = api.login_instructor()
    _exam(api, teacher)
    klass = api.create_cohort(teacher, "수업 1기")
    student = api.login("s1")
    api.join(student, klass["join_token"])
    api.open_scenarios(teacher, klass["id"], [S3])

    assert api.get(f"/api/cohorts/{klass['id']}/scenarios", student).status_code == 200
    assert api.get(f"/api/cohorts/{klass['id']}/scenarios/{S3}", student).status_code == 200
    assert api.get(f"/api/cohorts/{klass['id']}/scenarios/{S3}/prepare", student).status_code == 200
    res = api.submit(student, klass["id"], S3, s3_results(set(S3_CHECK_IDS)))
    assert res.status_code == 201, res.content
    assert res.json()["passed"] == len(S3_CHECK_IDS)
