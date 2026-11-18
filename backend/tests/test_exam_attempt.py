"""응시 흐름의 가장자리 — 인수 시험(test_spec_exam_attempt.py) 밖의 판단."""

from datetime import timedelta

import pytest
from django.test import Client
from django.utils import timezone

from exams.models import ExamInvite
from tests.api_helpers import S3, Session

pytestmark = pytest.mark.django_db

SETTINGS = {
    "time_limit_minutes": 30,
    "tools": [],
    "models": {},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 0,
}


def _invite(api):
    teacher = api.login_instructor()
    cohort = api.post("/api/instructor/cohorts", {"name": "회차", "kind": "exam"}, teacher).json()
    assert api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", SETTINGS, teacher).status_code == 200
    api.open_scenarios(teacher, cohort["id"], [S3])
    invite = api.post(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", {"label": "A"}, teacher).json()
    return teacher, cohort, invite


def test_someone_elses_session_cannot_start_or_finish(api):
    _, _, invite = _invite(api)
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    stranger = api.login("someone")

    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, stranger).status_code == 403
    assert api.post(f"/api/exam/{invite['token']}/finish", session=stranger).status_code == 403
    assert ExamInvite.objects.get(pk=invite["id"]).started_at is None


def test_enter_needs_the_dashboard_origin(api):
    _, _, invite = _invite(api)
    res = Client().post(f"/api/exam/{invite['token']}/enter", content_type="application/json")
    assert res.status_code == 403


def test_timed_out_attempt_reports_the_deadline_as_end(api):
    teacher, cohort, invite = _invite(api)
    cand = Session(client=Client(), username="")
    api.post(f"/api/exam/{invite['token']}/enter", session=cand)
    api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand)
    started = timezone.now() - timedelta(minutes=45)
    ExamInvite.objects.filter(pk=invite["id"]).update(started_at=started)

    row = api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", teacher).json()[0]
    assert row["status"] == "finished"
    # 늦게 「끝내기」를 눌러도 끝난 시각은 마감 시각이다.
    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200
    assert ExamInvite.objects.get(pk=invite["id"]).finished_at == started + timedelta(minutes=30)
    # 마감 뒤에도 시나리오는 읽을 수 있다(제출만 막힌다).
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}", cand).status_code == 200
