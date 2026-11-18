"""운영 배포 설정 — 헬스(DB 포함), 운영 설정 가드, 학생 compose 의 이미지 주소가 환경변수를 따르는지.

설정 모듈은 환경변수를 읽는 순간에 값이 정해진다 — `runpy` 로 지금 환경에서 새로 실행해 그 값을 본다
(이미 뜬 django.conf.settings 는 건드리지 않는다).
"""

import contextlib
import http.server
import runpy
import threading
import time
from pathlib import Path
from unittest import mock

import pytest
import yaml
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import OperationalError, connection
from django.test import override_settings

SETTINGS_FILE = str(Path(__file__).resolve().parent.parent / "config" / "settings.py")
STUDENT_IMAGE_VARS = ("AGENT_IMAGE", "WORKSTATION_IMAGE", "FLOCI_IMAGE")


def _fresh_settings(monkeypatch: pytest.MonkeyPatch, **env: str) -> dict[str, object]:
    cleared = (*STUDENT_IMAGE_VARS, "DJANGO_DEBUG", "DJANGO_SECRET_KEY")
    for name in (*cleared, "DJANGO_ALLOWED_HOSTS", "DJANGO_INTERNAL_HOSTS", "DJANGO_CSRF_TRUSTED_ORIGINS"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    return runpy.run_path(SETTINGS_FILE)


def _student_compose(api, images: dict[str, object]) -> dict:
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    with override_settings(**{k: images[k] for k in STUDENT_IMAGE_VARS}):
        res = api.get(f"/api/cohorts/{cohort['id']}/compose.yml", student)
    assert res.status_code == 200, res.content
    return yaml.safe_load(res.content)


@pytest.mark.django_db
def test_health_is_200_when_the_database_answers(client):
    res = client.get("/api/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "version": settings.INFRALAB_VERSION}


def _db_at(**override):
    params = {**connection.get_connection_params(), **override}
    return mock.patch.object(connection, "get_connection_params", return_value=params)


@pytest.mark.django_db
def test_health_is_503_when_the_database_refuses(client):
    # 닫힌 포트: 바로 거절된다. 본문에 호스트·포트·오류 원문이 없어야 한다.
    with _db_at(host="127.0.0.1", port=1):
        res = client.get("/api/health")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": settings.INFRALAB_VERSION}


@pytest.mark.django_db
def test_health_gives_up_on_an_unanswering_database_within_seconds(client):
    # 응답 없는 주소(라우팅 안 되는 TEST-NET): 연결 1초 제한으로 오래 걸리지 않는다.
    started = time.monotonic()
    with _db_at(host="192.0.2.1", port=5432):
        res = client.get("/api/health")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": settings.INFRALAB_VERSION}
    assert time.monotonic() - started < 3


@pytest.mark.django_db
def test_health_is_503_when_the_database_query_fails(client):
    with mock.patch("config.api.psycopg.connect", side_effect=OperationalError("password authentication failed for user x")):
        res = client.get("/api/health")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": settings.INFRALAB_VERSION}


@pytest.mark.django_db
def test_student_compose_uses_the_production_image_addresses_when_given(api, monkeypatch):
    images = _fresh_settings(
        monkeypatch,
        AGENT_IMAGE="ghcr.io/sandcorporation/infralab-agent:abc123",
        WORKSTATION_IMAGE="ghcr.io/sandcorporation/infralab-workstation:abc123",
    )
    doc = _student_compose(api, images)
    assert doc["services"]["agent"]["image"] == "ghcr.io/sandcorporation/infralab-agent:abc123"
    assert doc["services"]["workstation"]["image"] == "ghcr.io/sandcorporation/infralab-workstation:abc123"


@pytest.mark.django_db
def test_student_compose_keeps_the_local_images_when_not_given(api, monkeypatch):
    # compose 의 `${X:-}` 는 안 준 변수를 빈 문자열로 넘긴다 — 빈 값도 「안 줌」이다.
    images = _fresh_settings(monkeypatch, AGENT_IMAGE="")
    doc = _student_compose(api, images)
    assert doc["services"]["agent"]["image"] == "infralab/agent:dev"
    assert doc["services"]["workstation"]["image"] == "infralab/workstation:dev"
    assert doc["services"]["floci"]["image"] == "floci/floci:2.3.0"


def test_internal_hosts_are_allowed_even_when_the_env_lists_only_the_domain(monkeypatch):
    """운영 .env 가 도메인만 적어도 proxy 가 http://backend:8000 으로 부르는 내부 API 는 막히지 않는다(#82)."""
    s = _fresh_settings(
        monkeypatch,
        DJANGO_DEBUG="false",
        DJANGO_SECRET_KEY="test-only-secret",
        DJANGO_ALLOWED_HOSTS="infralab.sandcorp.co.kr",
        DJANGO_INTERNAL_HOSTS="backend, infralab.sandcorp.co.kr",
    )
    assert s["ALLOWED_HOSTS"] == ["infralab.sandcorp.co.kr", "backend"]


def test_production_refuses_the_development_secret_key(monkeypatch):
    with pytest.raises(ImproperlyConfigured, match="DJANGO_SECRET_KEY"):
        _fresh_settings(monkeypatch, DJANGO_DEBUG="false")


def test_production_settings_trust_the_proxy_and_read_hosts_and_origins(monkeypatch):
    s = _fresh_settings(
        monkeypatch,
        DJANGO_DEBUG="false",
        DJANGO_SECRET_KEY="test-only-secret",
        DJANGO_ALLOWED_HOSTS="infralab.sandcorp.co.kr, backend",
        DJANGO_CSRF_TRUSTED_ORIGINS="https://infralab.sandcorp.co.kr",
    )
    assert s["DEBUG"] is False
    assert s["ALLOWED_HOSTS"] == ["infralab.sandcorp.co.kr", "backend"]
    assert s["CSRF_TRUSTED_ORIGINS"] == ["https://infralab.sandcorp.co.kr"]
    assert s["SECURE_PROXY_SSL_HEADER"] == ("HTTP_X_FORWARDED_PROTO", "https")
    assert s["DEV_LOGIN_ENABLED"] is False
    assert s["SESSION_COOKIE_SECURE"] is True


#: 공개 주소 자리 — 헬스 점검이 이리로 가면 실패한다(내부 주소만 써야 한다).
DEAD_PUBLIC = "http://127.0.0.1:1"


@contextlib.contextmanager
def _fake_proxy(status: int):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.django_db
def test_health_skips_the_proxy_check_without_a_proxy_secret(client):
    with override_settings(EXAM_PROXY_SECRET="", EXAM_PROXY_INTERNAL_URL="http://127.0.0.1:1"):
        assert client.get("/api/health").status_code == 200


@pytest.mark.django_db
def test_health_checks_the_proxy_when_the_secret_is_set(client):
    with _fake_proxy(200) as url, override_settings(EXAM_PROXY_SECRET="s", EXAM_PROXY_INTERNAL_URL=url, EXAM_PROXY_URL=DEAD_PUBLIC):
        assert client.get("/api/health").json() == {"status": "ok", "version": settings.INFRALAB_VERSION}
    with override_settings(EXAM_PROXY_SECRET="s", EXAM_PROXY_INTERNAL_URL="http://127.0.0.1:1"):
        res = client.get("/api/health")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["proxy"], "version": settings.INFRALAB_VERSION}
    with _fake_proxy(500) as url, override_settings(EXAM_PROXY_SECRET="s", EXAM_PROXY_INTERNAL_URL=url, EXAM_PROXY_URL=DEAD_PUBLIC):
        assert client.get("/api/health").json() == {"status": "error", "failed": ["proxy"], "version": settings.INFRALAB_VERSION}


@pytest.mark.django_db
def test_health_scope_ready_ignores_a_dead_proxy_but_not_a_dead_db(client):
    with override_settings(EXAM_PROXY_SECRET="s", EXAM_PROXY_INTERNAL_URL="http://127.0.0.1:1"):
        assert client.get("/api/health?scope=ready").json() == {"status": "ok", "version": settings.INFRALAB_VERSION}
        with _db_at(host="127.0.0.1", port=1):
            res = client.get("/api/health?scope=ready")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": settings.INFRALAB_VERSION}


def test_compose_pins_the_internal_proxy_url_for_backend():
    """backend → proxy 직접 호출은 .env 의 공개 주소와 상관없이 compose 안 주소로 간다."""
    doc = yaml.safe_load((Path(SETTINGS_FILE).parents[2] / "compose.prod.yml").read_text(encoding="utf-8"))
    env = doc["services"]["backend"]["environment"]
    assert env["INFRALAB_EXAM_PROXY_INTERNAL_URL"] == "http://proxy:58090"


def test_internal_proxy_url_has_its_own_setting(monkeypatch):
    s = _fresh_settings(
        monkeypatch,
        INFRALAB_EXAM_PROXY_URL="https://infralab.example/exam-proxy/",
        INFRALAB_EXAM_PROXY_INTERNAL_URL="http://proxy:58090/",
    )
    assert s["EXAM_PROXY_URL"] == "https://infralab.example/exam-proxy"
    assert s["EXAM_PROXY_INTERNAL_URL"] == "http://proxy:58090"
