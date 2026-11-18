"""가짜 공급사 AI 프록시는 e2e 스택에만 — compose 파일 세 개의 proxy·backend 환경.

target: backend/tests/test_spec_e2e_followup_proxy.py
AC: #195: docker/compose.e2e.yaml 에 서비스 proxy 가 가짜 공급사 모드(INFRALAB_PROXY_FAKE_PROVIDER "1")로 뜨고, backend 가 그 프록시를 쓴다(공유 비밀·내부 주소)
AC: #195: docker/compose.dev.yaml·compose.prod.yml 에는 가짜 공급사 모드가 없다(값이 없거나 거짓)

운영 설정으로 띄운 스택에서 가짜 공급사 길이 꺼져 있음을 compose 파일로 본다(프록시 자체의 기본값 꺼짐은
proxy/proxy_test.go 가 본다). e2e 의 화면 흐름(「AI 키 설정」·토큰 회수 401)은 web/e2e 시험이 본다.
"""

from pathlib import Path

import pytest
from tests.compose_yaml import load_compose

REPO = Path(__file__).resolve().parents[2]
FAKE = "INFRALAB_PROXY_FAKE_PROVIDER"


def _services(compose_file: Path) -> dict:
    return load_compose(compose_file)["services"]


def _env(services: dict, name: str) -> dict:
    return (services.get(name) or {}).get("environment") or {}


def test_e2e_compose_runs_the_proxy_in_fake_provider_mode():
    services = _services(REPO / "docker" / "compose.e2e.yaml")
    assert "proxy" in services
    assert str(_env(services, "proxy").get(FAKE)) == "1"


def test_e2e_backend_talks_to_the_e2e_proxy_with_its_shared_secret():
    services = _services(REPO / "docker" / "compose.e2e.yaml")
    backend = _env(services, "backend")
    proxy = _env(services, "proxy")
    assert str(backend.get("INFRALAB_EXAM_PROXY_INTERNAL_URL", "")).startswith("http://proxy:")
    secret = str(backend.get("INFRALAB_EXAM_PROXY_SECRET") or "")
    assert secret
    assert str(proxy.get("INFRALAB_EXAM_PROXY_SECRET")) == secret


def test_dev_and_production_compose_never_turn_the_fake_provider_on():
    for compose_file in (REPO / "docker" / "compose.dev.yaml", REPO / "compose.prod.yml"):
        for name, service in _services(compose_file).items():
            env = (service or {}).get("environment") or {}
            value = str(env.get(FAKE) or "").strip().lower()
            assert value in {"", "0", "false", "no", "off"}, f"{compose_file.name}: {name} 의 {FAKE}={value}"
