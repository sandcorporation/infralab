"""공급사 키가 하나만 있을 때 — 키 없는 공급사의 도구를 시험 설정·AI 키 설정에서 막는다(#120).

backend 는 공급사 키를 갖지 않고 AI 프록시 `GET /providers` 로 설정 여부만 묻는다. 여기서는 프록시 자리에
진짜 HTTP 서버를 띄워 그 계약(공유 비밀, `{"anthropic": bool, "openai": bool}`)을 흉내 낸다.
프록시를 못 부르면 「모름」이고 아무 도구도 막지 않는다.
"""

from __future__ import annotations

import json
import socket
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from django.test import override_settings

from tests.test_spec_exam_ai_token import EXAM_SETTINGS, _ai_config, _candidate, _exam, _invite

SECRET = "proxy-secret-for-tests"
ANTHROPIC_ONLY = {"anthropic": True, "openai": False}

pytestmark = pytest.mark.django_db


class FakeProxy:
    def __init__(self) -> None:
        self.answer: dict[str, bool] = {"anthropic": True, "openai": True}
        self.calls: list[str | None] = []


@pytest.fixture
def fake_proxy() -> Iterator[FakeProxy]:
    state = FakeProxy()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 — http.server 이름
            auth = self.headers.get("Authorization")
            state.calls.append(auth)
            if self.path != "/providers" or auth != f"Bearer {SECRET}":
                self.send_response(401)
                self.end_headers()
                return
            body = json.dumps(state.answer).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    with override_settings(EXAM_PROXY_URL=f"http://127.0.0.1:{server.server_port}", EXAM_PROXY_SECRET=SECRET):
        yield state
    server.shutdown()
    server.server_close()


def _closed_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _put_settings(api, teacher, cohort_id, settings):
    return api.put(f"/api/instructor/cohorts/{cohort_id}/exam-settings", settings, teacher)


def _new_exam_cohort(api, teacher):
    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    return res.json()


def test_exam_providers_lists_tools_whose_provider_key_is_missing(api, fake_proxy):
    fake_proxy.answer = ANTHROPIC_ONLY
    teacher = api.login_instructor()

    res = api.get("/api/instructor/exam-providers", teacher)

    assert res.status_code == 200, res.content
    assert res.json() == {"unavailable_tools": ["codex"]}
    assert fake_proxy.calls == [f"Bearer {SECRET}"]


def test_exam_providers_needs_an_instructor(api, fake_proxy):
    assert api.get("/api/instructor/exam-providers").status_code == 401


def test_settings_reject_a_tool_without_provider_key(api, fake_proxy):
    fake_proxy.answer = ANTHROPIC_ONLY
    teacher = api.login_instructor()
    cohort = _new_exam_cohort(api, teacher)

    res = _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS)

    assert res.status_code == 400
    assert "codex" in res.json()["detail"] and "openai" in res.json()["detail"]
    ok = {**EXAM_SETTINGS, "tools": ["claude_code", "local_llm"], "models": {"claude_code": "claude-sonnet-4-5"}}
    assert _put_settings(api, teacher, cohort["id"], ok).status_code == 200


def test_proxy_answer_is_cached_briefly(api, fake_proxy):
    fake_proxy.answer = ANTHROPIC_ONLY
    teacher = api.login_instructor()

    for _ in range(3):
        api.get("/api/instructor/exam-providers", teacher)

    assert len(fake_proxy.calls) == 1


@pytest.mark.parametrize(
    "overrides",
    [
        {"EXAM_PROXY_SECRET": ""},  # 개발 — 프록시를 쓰지 않는다
        {"EXAM_PROXY_URL": f"http://127.0.0.1:{_closed_port()}", "EXAM_PROXY_SECRET": SECRET},  # 프록시가 죽음
    ],
)
def test_unknown_providers_block_nothing(api, overrides):
    teacher = api.login_instructor()
    cohort = _new_exam_cohort(api, teacher)

    with override_settings(**overrides):
        assert api.get("/api/instructor/exam-providers", teacher).json() == {"unavailable_tools": []}
        assert _put_settings(api, teacher, cohort["id"], EXAM_SETTINGS).status_code == 200


def test_ai_config_drops_a_saved_tool_whose_provider_key_went_missing(api, fake_proxy):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)  # 두 키가 다 있을 때 claude_code·codex 로 저장
    invite = _invite(api, teacher, cohort["id"])
    cand = _candidate(api, invite["token"])
    from exams import providers

    providers.clear_cache()
    fake_proxy.answer = ANTHROPIC_ONLY

    config = _ai_config(api, cand, invite["token"])

    assert [t["tool"] for t in config["tools"]] == ["claude_code"]
