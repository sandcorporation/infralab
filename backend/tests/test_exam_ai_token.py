"""임시 토큰 — 인수 시험(test_spec_exam_ai_token.py) 밖의 판단: 한도 0, 발급 전 회수, 비밀 없음, 응시 링크 회수."""

import pytest
from django.test import Client, override_settings

from tests.api_helpers import S3, Session

SECRET = "proxy-secret-for-tests"
SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 0,
}

pytestmark = pytest.mark.django_db


@pytest.fixture(autouse=True)
def proxy_settings():
    with override_settings(EXAM_PROXY_URL="https://proxy.infralab.test/", EXAM_PROXY_SECRET=SECRET):
        yield


def _setup(api, settings=SETTINGS, start=True):
    teacher = api.login_instructor()
    cohort = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher).json()
    assert api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", settings, teacher).status_code == 200
    api.open_scenarios(teacher, cohort["id"], [S3])
    invite = api.post(f"/api/instructor/cohorts/{cohort['id']}/exam-invites", {"label": "A"}, teacher).json()
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    if start:
        assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 200
    return teacher, cohort, invite, cand


def _authorize(token, secret=SECRET):
    return Client().post(
        "/api/proxy/authorize",
        data={"token": token, "tool": "claude_code", "client_id": "c"},
        content_type="application/json",
        HTTP_AUTHORIZATION=f"Bearer {secret}",
    )


def test_zero_limit_means_no_limit(api):
    _, _, invite, cand = _setup(api)
    config = api.get(f"/api/exam/{invite['token']}/ai-config", cand).json()

    # 주소 끝의 / 는 한 번만 붙는다.
    assert config["proxy_url"] == "https://proxy.infralab.test"
    assert config["tools"][0]["env"]["ANTHROPIC_BASE_URL"] == "https://proxy.infralab.test/anthropic"
    assert _authorize(config["token"]).json() == {
        "allowed": True,
        "reason": None,
        "model": "claude-sonnet-4-5",
        "remaining_tokens": None,
    }


def test_revoking_before_issue_keeps_ai_config_closed(api):
    teacher, cohort, invite, cand = _setup(api)
    path = f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}/ai-token/revoke"

    assert api.post(path, session=teacher).status_code == 204
    assert api.post(path, session=teacher).status_code == 204
    assert api.get(f"/api/exam/{invite['token']}/ai-config", cand).status_code == 409


def test_empty_secret_refuses_everyone(api):
    _, _, invite, cand = _setup(api)
    token = api.get(f"/api/exam/{invite['token']}/ai-config", cand).json()["token"]

    with override_settings(EXAM_PROXY_SECRET=""):
        assert _authorize(token, secret="").status_code == 401


def test_revoked_invite_link_revokes_the_token(api):
    teacher, cohort, invite, cand = _setup(api)
    token = api.get(f"/api/exam/{invite['token']}/ai-config", cand).json()["token"]

    assert api.delete(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}", session=teacher).status_code == 204

    assert _authorize(token).json()["reason"] == "revoked"
