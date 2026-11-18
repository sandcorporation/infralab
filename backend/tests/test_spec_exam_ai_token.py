"""임시 토큰 — 지원자의 AI 키 설정 받기, 프록시 전용 내부 API(확인·기록), 담당자 회수, 마감 회수.

target: backend/tests/test_spec_exam_ai_token.py
AC: #72: 시작 뒤 ai-config 가 허용 도구마다 설정(claude_code env, codex config_toml + env)을 준다. 허용하지 않은 도구는 없고, 다시 불러도 같은 토큰
AC: #72: 시작 전·마감 뒤·회수 뒤 ai-config 409
AC: #72: POST /api/proxy/authorize 는 공유 비밀이 틀리면 401, 허용이면 {allowed: true, model, remaining_tokens}
AC: #72: 거절 사유 unknown·revoked·outside_window·tool_not_allowed·limit·in_use_elsewhere(5분이 지나면 새 클라이언트가 이어 쓴다)
AC: #72: POST /api/proxy/exchanges 가 요청·응답·사용량을 기록하고 사용량을 한도에서 깎는다
AC: #72: 담당자가 ai-token/revoke 하면 다음 확인부터 revoked, 남의 조직이면 404
AC: #72: 지원자가 finish 하면 토큰이 회수된다

지원자 화면은 응시 세션으로 ai-config 를 부르고, 프록시 자리는 쿠키 없는 테스트 클라이언트가
`Authorization: Bearer <EXAM_PROXY_SECRET>` 로 내부 API 를 부른다. 프록시 주소·비밀은 시험 값으로 덮는다.
「export K="V"」 줄 만들기(웹)는 web/src/spec/spec_exam_ai_token.test.ts 가 본다.
"""

from datetime import timedelta

import pytest
from django.test import Client, override_settings
from django.utils import timezone

from tests.api_helpers import S3, Session

PROXY_URL = "https://proxy.infralab.test"
SECRET = "proxy-secret-for-tests"
CLAUDE_MODEL = "claude-sonnet-4-5"
CODEX_MODEL = "gpt-5-codex"

EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code", "codex"],
    "models": {"claude_code": CLAUDE_MODEL, "codex": CODEX_MODEL},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 1000,
}

pytestmark = [pytest.mark.django_db, pytest.mark.usefixtures("proxy_settings")]


@pytest.fixture
def proxy_settings():
    with override_settings(EXAM_PROXY_URL=PROXY_URL, EXAM_PROXY_SECRET=SECRET):
        yield


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


def _candidate(api, token, start=True) -> Session:
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{token}/enter", session=cand).status_code == 200
    if start:
        res = api.post(f"/api/exam/{token}/start", {"consent": True}, cand)
        assert res.status_code == 200, res.content
    return cand


def _setup(api, settings=EXAM_SETTINGS):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher, settings)
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])
    return teacher, cohort, invite, cand


def _ai_config(api, cand, invite_token):
    res = api.get(f"/api/exam/{invite_token}/ai-config", cand)
    assert res.status_code == 200, res.content
    return res.json()


def _proxy(path, body, secret=SECRET):
    headers = {"HTTP_AUTHORIZATION": f"Bearer {secret}"} if secret is not None else {}
    return Client().post(path, data=body, content_type="application/json", **headers)


def _authorize(ai_token, tool="claude_code", client_id="10.0.0.5", secret=SECRET):
    return _proxy("/api/proxy/authorize", {"token": ai_token, "tool": tool, "client_id": client_id}, secret)


def _exchange(ai_token, input_tokens=100, output_tokens=50, tool="claude_code", client_id="10.0.0.5", **extra):
    body = {
        "token": ai_token,
        "tool": tool,
        "model": CLAUDE_MODEL if tool == "claude_code" else CODEX_MODEL,
        "client_id": client_id,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "request": extra.get("request", '{"messages":[{"role":"user","content":"버킷을 만들어 줘"}]}'),
        "response": extra.get("response", '{"content":[{"type":"text","text":"aws s3 mb 로 만듭니다"}]}'),
    }
    return _proxy("/api/proxy/exchanges", body)


def _verdict(ai_token, **kw):
    res = _authorize(ai_token, **kw)
    assert res.status_code == 200, res.content
    return res.json()


# ---------- ai-config ----------


@pytest.mark.skip(reason="#72")
def test_ai_config_gives_one_setting_per_allowed_tool(api):
    teacher, cohort, invite, cand = _setup(api)

    config = _ai_config(api, cand, invite["token"])

    assert config["proxy_url"] == PROXY_URL
    ai_token = config["token"]
    assert ai_token and ai_token != invite["token"]
    tools = {t["tool"]: t for t in config["tools"]}
    assert set(tools) == {"claude_code", "codex"}

    claude = tools["claude_code"]
    assert claude["model"] == CLAUDE_MODEL
    assert claude["env"]["ANTHROPIC_BASE_URL"].startswith(PROXY_URL)
    assert claude["env"]["ANTHROPIC_AUTH_TOKEN"] == ai_token
    assert claude["env"]["ANTHROPIC_MODEL"] == CLAUDE_MODEL
    assert claude["config_toml"] == ""

    codex = tools["codex"]
    assert codex["model"] == CODEX_MODEL
    assert PROXY_URL in codex["config_toml"]
    assert CODEX_MODEL in codex["config_toml"]
    assert ai_token in codex["env"].values()
    # 진짜 공급사 키 이름은 지원자에게 가지 않는다.
    assert "EXAM_KEY" not in str(config)


@pytest.mark.skip(reason="#72")
def test_ai_config_lists_only_allowed_tools_and_keeps_the_same_token(api):
    only_claude = {**EXAM_SETTINGS, "tools": ["claude_code"], "models": {"claude_code": CLAUDE_MODEL}}
    teacher, cohort, invite, cand = _setup(api, only_claude)

    first = _ai_config(api, cand, invite["token"])
    second = _ai_config(api, cand, invite["token"])

    assert [t["tool"] for t in first["tools"]] == ["claude_code"]
    assert first["token"] == second["token"]


@pytest.mark.skip(reason="#72")
def test_ai_config_is_409_before_start_after_finish_and_after_revoke(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)

    waiting = _invite(api, teacher, cohort["id"], "시작 전")
    early = _candidate(api, waiting["token"], start=False)
    assert api.get(f"/api/exam/{waiting['token']}/ai-config", early).status_code == 409

    done = _invite(api, teacher, cohort["id"], "마감")
    finished = _candidate(api, done["token"])
    _ai_config(api, finished, done["token"])
    assert api.post(f"/api/exam/{done['token']}/finish", session=finished).status_code == 200
    assert api.get(f"/api/exam/{done['token']}/ai-config", finished).status_code == 409

    cut = _invite(api, teacher, cohort["id"], "회수")
    revoked = _candidate(api, cut["token"])
    _ai_config(api, revoked, cut["token"])
    res = api.post(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{cut['id']}/ai-token/revoke", session=teacher)
    assert res.status_code == 204
    assert api.get(f"/api/exam/{cut['token']}/ai-config", revoked).status_code == 409


# ---------- 프록시 확인 ----------


@pytest.mark.skip(reason="#72")
def test_authorize_needs_the_shared_secret(api):
    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    assert _authorize(ai_token, secret="wrong").status_code == 401
    assert _authorize(ai_token, secret=None).status_code == 401
    assert _proxy("/api/proxy/exchanges", {"token": ai_token}, secret="wrong").status_code == 401


@pytest.mark.skip(reason="#72")
def test_authorize_allows_with_the_fixed_model_and_the_remaining_budget(api):
    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    assert _verdict(ai_token) == {"allowed": True, "reason": None, "model": CLAUDE_MODEL, "remaining_tokens": 1000}
    codex = _verdict(ai_token, tool="codex")
    assert codex["allowed"] is True and codex["model"] == CODEX_MODEL


@pytest.mark.skip(reason="#72")
def test_authorize_refuses_an_unknown_token(api):
    verdict = _verdict("no-such-token")
    assert verdict["allowed"] is False and verdict["reason"] == "unknown"


@pytest.mark.skip(reason="#72")
def test_authorize_refuses_after_the_deadline(api):
    from exams.models import ExamInvite

    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    ExamInvite.objects.filter(pk=invite["id"]).update(started_at=timezone.now() - timedelta(minutes=61))

    verdict = _verdict(ai_token)
    assert verdict["allowed"] is False and verdict["reason"] == "outside_window"


@pytest.mark.skip(reason="#72")
def test_authorize_refuses_a_tool_the_exam_does_not_allow(api):
    only_claude = {**EXAM_SETTINGS, "tools": ["claude_code"], "models": {"claude_code": CLAUDE_MODEL}}
    teacher, cohort, invite, cand = _setup(api, only_claude)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    verdict = _verdict(ai_token, tool="codex")
    assert verdict["allowed"] is False and verdict["reason"] == "tool_not_allowed"
    assert _verdict(ai_token)["allowed"] is True


@pytest.mark.skip(reason="#72")
def test_exchanges_are_recorded_and_spend_the_budget(api):
    from exams.models import AIExchange

    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    res = _exchange(ai_token, input_tokens=300, output_tokens=200, request="REQ-1", response="RESP-1")

    assert res.status_code == 204
    assert _verdict(ai_token)["remaining_tokens"] == 500
    rows = list(AIExchange.objects.filter(ai_token__token=ai_token))
    assert [(r.tool, r.model, r.client_id, r.request, r.response, r.input_tokens, r.output_tokens) for r in rows] == [
        ("claude_code", CLAUDE_MODEL, "10.0.0.5", "REQ-1", "RESP-1", 300, 200)
    ]
    assert _exchange("no-such-token").status_code == 404


@pytest.mark.skip(reason="#72")
def test_authorize_refuses_when_the_budget_is_spent(api):
    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    assert _exchange(ai_token, input_tokens=600, output_tokens=500).status_code == 204

    verdict = _verdict(ai_token)
    assert verdict["allowed"] is False and verdict["reason"] == "limit"


@pytest.mark.skip(reason="#72")
def test_a_second_client_is_refused_while_the_first_is_in_use_and_takes_over_after_five_minutes(api):
    from exams.models import AIToken

    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    assert _verdict(ai_token, client_id="client-a")["allowed"] is True
    assert _exchange(ai_token, client_id="client-a").status_code == 204
    assert _verdict(ai_token, client_id="client-a")["allowed"] is True

    elsewhere = _verdict(ai_token, client_id="client-b")
    assert elsewhere["allowed"] is False and elsewhere["reason"] == "in_use_elsewhere"

    AIToken.objects.filter(token=ai_token).update(last_used_at=timezone.now() - timedelta(minutes=6))

    assert _verdict(ai_token, client_id="client-b")["allowed"] is True


# ---------- 회수 ----------


@pytest.mark.skip(reason="#72")
def test_instructor_revokes_the_token_at_once(api):
    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]
    path = f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}/ai-token/revoke"

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert api.post(path, session=outsider).status_code == 404
    assert _verdict(ai_token)["allowed"] is True

    res = api.post(path, session=teacher)

    assert res.status_code == 204
    verdict = _verdict(ai_token)
    assert verdict["allowed"] is False and verdict["reason"] == "revoked"


@pytest.mark.skip(reason="#72")
def test_finishing_the_exam_revokes_the_token(api):
    teacher, cohort, invite, cand = _setup(api)
    ai_token = _ai_config(api, cand, invite["token"])["token"]

    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200

    verdict = _verdict(ai_token)
    assert verdict["allowed"] is False and verdict["reason"] == "revoked"
