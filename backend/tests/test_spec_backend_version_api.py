"""backend 버전 — health 본문의 version, 모든 /api/ 응답의 X-Infralab-Version 헤더.

target: backend/tests/test_spec_backend_version_api.py
AC: #179: INFRALAB_VERSION=abc123 이면 settings.INFRALAB_VERSION == "abc123", 없거나 빈 값이면 "dev"
AC: #179: health 200 본문이 {"status": "ok", "version": <값>} — 기존 키와 상태 코드는 그대로
AC: #179: DB 가 죽어 health 가 503 일 때(기본·scope=ready 모두) 본문이 {"status": "error", "failed": ["db"], "version": <값>}
AC: #179: /api/accounts/me 를 인증 없이 부르면 401 이고 헤더 X-Infralab-Version 이 버전 값이다. 404·health 응답에도 같은 헤더

설정 모듈은 `runpy` 로 지금 환경에서 새로 실행해 환경변수 → 설정 값을 보고, HTTP 쪽은 override_settings 로
버전을 정한 뒤 테스트 클라이언트로 본문과 헤더를 본다. DB 죽음은 연결 대상을 닫힌 포트로 바꿔 만든다.
"""

import runpy
from pathlib import Path
from unittest import mock

import pytest
from django.db import connection
from django.test import override_settings

SETTINGS_FILE = str(Path(__file__).resolve().parent.parent / "config" / "settings.py")
HEADER = "X-Infralab-Version"


def _settings_with(monkeypatch: pytest.MonkeyPatch, version: str | None) -> dict[str, object]:
    monkeypatch.delenv("INFRALAB_VERSION", raising=False)
    if version is not None:
        monkeypatch.setenv("INFRALAB_VERSION", version)
    return runpy.run_path(SETTINGS_FILE)


def _db_dead():
    params = {**connection.get_connection_params(), "host": "127.0.0.1", "port": 1}
    return mock.patch.object(connection, "get_connection_params", return_value=params)


# ---------- 설정 ----------


def test_version_setting_reads_the_environment(monkeypatch):
    assert _settings_with(monkeypatch, "abc123")["INFRALAB_VERSION"] == "abc123"


def test_version_setting_is_dev_without_the_variable(monkeypatch):
    assert _settings_with(monkeypatch, None)["INFRALAB_VERSION"] == "dev"


def test_version_setting_is_dev_when_the_variable_is_empty(monkeypatch):
    assert _settings_with(monkeypatch, "")["INFRALAB_VERSION"] == "dev"


# ---------- health 본문 ----------


@pytest.mark.django_db
def test_health_200_body_carries_the_version(client):
    with override_settings(INFRALAB_VERSION="abc123", EXAM_PROXY_SECRET=""):
        res = client.get("/api/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "version": "abc123"}


@pytest.mark.django_db
def test_health_200_body_says_dev_by_default(client):
    with override_settings(INFRALAB_VERSION="dev", EXAM_PROXY_SECRET=""):
        res = client.get("/api/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "version": "dev"}


@pytest.mark.django_db
def test_health_scope_ready_200_body_carries_the_version(client):
    with override_settings(INFRALAB_VERSION="abc123", EXAM_PROXY_SECRET=""):
        res = client.get("/api/health?scope=ready")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "version": "abc123"}


@pytest.mark.django_db
def test_health_503_body_carries_the_version_when_the_database_is_dead(client):
    with override_settings(INFRALAB_VERSION="abc123", EXAM_PROXY_SECRET=""), _db_dead():
        res = client.get("/api/health")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": "abc123"}


@pytest.mark.django_db
def test_health_scope_ready_503_body_carries_the_version(client):
    with override_settings(INFRALAB_VERSION="abc123", EXAM_PROXY_SECRET=""), _db_dead():
        res = client.get("/api/health?scope=ready")
    assert res.status_code == 503
    assert res.json() == {"status": "error", "failed": ["db"], "version": "abc123"}


# ---------- 응답 헤더 ----------


@pytest.mark.django_db
def test_unauthenticated_me_401_carries_the_version_header(client):
    with override_settings(INFRALAB_VERSION="abc123"):
        res = client.get("/api/accounts/me")
    assert res.status_code == 401
    assert res.headers[HEADER] == "abc123"


@pytest.mark.django_db
def test_api_404_carries_the_version_header(client):
    with override_settings(INFRALAB_VERSION="abc123"):
        res = client.get("/api/no-such-endpoint")
    assert res.status_code == 404
    assert res.headers[HEADER] == "abc123"


@pytest.mark.django_db
def test_health_carries_the_version_header(client):
    with override_settings(INFRALAB_VERSION="dev", EXAM_PROXY_SECRET=""):
        res = client.get("/api/health")
    assert res.status_code == 200
    assert res.headers[HEADER] == "dev"
