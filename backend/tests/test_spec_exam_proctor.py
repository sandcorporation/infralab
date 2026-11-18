"""감독 신호 — 지원자 화면의 탭 이탈·포커스·붙여넣기, 서버가 남기는 프록시 밖 AI 사용, 담당자 조회.

target: backend/tests/test_spec_exam_proctor.py
AC: #75: 응시 중 POST /api/exam/{token}/events 로 tab_hidden·focus_lost·paste 를 남긴다(204), 모르는 종류 422
AC: #75: 시작 전·마감 뒤 409, 감독을 끈 회차에서는 204 지만 남지 않는다
AC: #75: 담당자 GET …/exam-invites/{id}/events 가 신호를 시각순으로 준다(kind, detail, at), 남의 조직 404
AC: #75: 응시 링크 목록의 각 항목에 event_count
AC: #75: 시험 회차 제출에 Claude 발화가 있는데 프록시 기록에 claude_code 요청이 없으면 ai_outside_proxy(세부에 도구 이름), 있으면 없다
AC: #75: 수업 묶음 제출에는 신호가 생기지 않는다

지원자는 로그인 없는 새 테스트 클라이언트로 응시 링크에 들어온다. 프록시 기록은 프록시 전용 내부 API
(`/api/proxy/exchanges`, #72)로 남긴다. 브라우저 이벤트를 보내는 화면은 티켓의 「손 확인」이다.
"""

from datetime import datetime

import pytest
from django.test import Client, override_settings

from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

pytestmark = pytest.mark.django_db

SECRET = "proxy-secret-for-tests"
EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": True,
    "hidden_checks": False,
    "ai_token_limit": 100000,
}

CLAUDE_TRANSCRIPT = {
    "tool": "claude",
    "since": "2026-11-18T09:00:00Z",
    "truncated": False,
    "entries": [
        {"role": "user", "at": "2026-11-18T09:01:00Z", "text": "버킷 만들어 줘"},
        {"role": "assistant", "at": "2026-11-18T09:01:05Z", "text": "aws s3 mb s3://lab-site 로 만듭니다."},
    ],
}


def _exam(api, teacher, settings=EXAM_SETTINGS):
    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
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


def _candidate(api, token, start=True):
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{token}/enter", session=cand).status_code == 200
    if start:
        assert api.post(f"/api/exam/{token}/start", {"consent": True}, cand).status_code == 200
    return cand


def _event(api, cand, token, kind, detail=None):
    body = {"kind": kind} if detail is None else {"kind": kind, "detail": detail}
    return api.post(f"/api/exam/{token}/events", body, cand)


def _events(api, teacher, cohort_id, invite_id):
    return api.get(f"/api/instructor/cohorts/{cohort_id}/exam-invites/{invite_id}/events", teacher)


def _submit_with_transcript(api, cand, cohort_id, transcript):
    body = {"agent_version": "0.4.0", "results": s3_results(set(S3_CHECK_IDS)), "ai_transcript": transcript}
    res = api.post(f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions", body, cand)
    assert res.status_code == 201, res.content
    return res


@pytest.mark.skip(reason="#75")
def test_candidate_signals_are_recorded_in_time_order(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])

    assert _event(api, cand, invite["token"], "tab_hidden").status_code == 204
    assert _event(api, cand, invite["token"], "focus_lost").status_code == 204
    assert _event(api, cand, invite["token"], "paste", "aws s3 mb s3://lab-site").status_code == 204

    res = _events(api, teacher, cohort["id"], invite["id"])
    assert res.status_code == 200, res.content
    events = res.json()
    assert [(e["kind"], e["detail"]) for e in events] == [
        ("tab_hidden", ""),
        ("focus_lost", ""),
        ("paste", "aws s3 mb s3://lab-site"),
    ]
    times = [datetime.fromisoformat(e["at"].replace("Z", "+00:00")) for e in events]
    assert times == sorted(times)


@pytest.mark.skip(reason="#75")
def test_unknown_signal_kind_is_422(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])

    assert _event(api, cand, invite["token"], "webcam_off").status_code == 422
    # 서버만 남기는 종류는 지원자가 보낼 수 없다.
    assert _event(api, cand, invite["token"], "ai_outside_proxy").status_code == 422
    assert _events(api, teacher, cohort["id"], invite["id"]).json() == []


@pytest.mark.skip(reason="#75")
def test_signals_before_start_and_after_finish_are_409(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"], start=False)

    assert _event(api, cand, invite["token"], "tab_hidden").status_code == 409

    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 200
    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200
    assert _event(api, cand, invite["token"], "paste").status_code == 409
    assert _events(api, teacher, cohort["id"], invite["id"]).json() == []


@pytest.mark.skip(reason="#75")
def test_signals_without_proctoring_are_accepted_but_not_kept(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher, {**EXAM_SETTINGS, "proctoring": False})
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])

    assert _event(api, cand, invite["token"], "tab_hidden").status_code == 204

    assert _events(api, teacher, cohort["id"], invite["id"]).json() == []


@pytest.mark.skip(reason="#75")
def test_events_of_another_orgs_invite_are_404(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert _events(api, outsider, cohort["id"], invite["id"]).status_code == 404
    other = _exam(api, teacher)
    assert _events(api, teacher, other["id"], invite["id"]).status_code == 404


@pytest.mark.skip(reason="#75")
def test_invite_list_counts_signals_per_candidate(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    noisy = _invite(api, teacher, cohort["id"], "지원자 A")
    quiet = _invite(api, teacher, cohort["id"], "지원자 B")
    cand = _candidate(api, noisy["token"])
    _candidate(api, quiet["token"])
    for kind in ("tab_hidden", "focus_lost", "paste"):
        _event(api, cand, noisy["token"], kind)

    listed = api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", teacher).json()

    assert {i["id"]: i["event_count"] for i in listed} == {noisy["id"]: 3, quiet["id"]: 0}


@pytest.mark.skip(reason="#75")
def test_claude_transcript_without_proxy_use_leaves_an_outside_proxy_signal(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])

    _submit_with_transcript(api, cand, cohort["id"], [CLAUDE_TRANSCRIPT])

    outside = [e for e in _events(api, teacher, cohort["id"], invite["id"]).json() if e["kind"] == "ai_outside_proxy"]
    assert len(outside) == 1
    assert "claude" in outside[0]["detail"]


@pytest.mark.skip(reason="#75")
def test_claude_transcript_with_proxy_use_leaves_no_signal(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])
    with override_settings(EXAM_PROXY_SECRET=SECRET):
        config = api.get(f"/api/exam/{invite['token']}/ai-config", cand)
        assert config.status_code == 200, config.content
        res = Client().post(
            "/api/proxy/exchanges",
            data={
                "token": config.json()["token"],
                "tool": "claude_code",
                "model": "claude-sonnet-4-5",
                "client_id": "10.0.0.5",
                "input_tokens": 10,
                "output_tokens": 20,
                "request": "버킷 만들어 줘",
                "response": "aws s3 mb s3://lab-site 로 만듭니다.",
            },
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {SECRET}",
        )
        assert res.status_code == 204, res.content

    _submit_with_transcript(api, cand, cohort["id"], [CLAUDE_TRANSCRIPT])

    kinds = [e["kind"] for e in _events(api, teacher, cohort["id"], invite["id"]).json()]
    assert "ai_outside_proxy" not in kinds


@pytest.mark.skip(reason="#75")
def test_transcript_of_a_tool_the_exam_does_not_allow_leaves_a_signal(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])
    codex = {**CLAUDE_TRANSCRIPT, "tool": "codex"}

    _submit_with_transcript(api, cand, cohort["id"], [codex])

    outside = [e for e in _events(api, teacher, cohort["id"], invite["id"]).json() if e["kind"] == "ai_outside_proxy"]
    assert len(outside) == 1
    assert "codex" in outside[0]["detail"]


@pytest.mark.skip(reason="#75")
def test_class_cohort_submissions_leave_no_signal(api):
    teacher = api.login_instructor()
    exam = _exam(api, teacher)
    invite = _invite(api, teacher, exam["id"])
    _candidate(api, invite["token"])
    klass = api.create_cohort(teacher, "수업 1기")
    student = api.login("s1")
    api.join(student, klass["join_token"])
    api.open_scenarios(teacher, klass["id"], [S3])

    _submit_with_transcript(api, student, klass["id"], [CLAUDE_TRANSCRIPT])

    assert _events(api, teacher, exam["id"], invite["id"]).json() == []
    assert [i["event_count"] for i in api.get(f"/api/instructor/cohorts/{exam['id']}/exam-invites", teacher).json()] == [0]
