"""시험 모드 운영 배선 — compose.prod.yml 의 프록시·backend 환경과 문제은행 볼륨, 배포 문서.

target: backend/tests/test_spec_exam_deploy.py
AC: #81: compose.prod.yml 에 proxy 서비스가 있고 그 환경에 공급사 키 둘과 공유 비밀이 있다
AC: #81: backend 환경에 공유 비밀·프록시 주소·채점 키·INFRALAB_PROBLEMS_DIR 가 있고 공급사 키는 없다
AC: #81: backend 의 INFRALAB_PROBLEMS_DIR 은 컨테이너 안 절대 경로이고 그 자리에 볼륨이 붙는다
AC: #81: docs/ops/deploy.md 가 새 환경변수 이름, 문제은행 자격 이름, problems.ref 를 모두 적는다

저장소 파일을 읽어 본다(yaml.safe_load 는 `<<: *anchor` 병합을 푼다). Jenkinsfile 의 문제은행 받기는
운영 서버에서만 확인할 수 있어 티켓의 「손 확인」이다.
"""

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
PROVIDER_KEYS = ("INFRALAB_ANTHROPIC_EXAM_KEY", "INFRALAB_OPENAI_EXAM_KEY")
SHARED_SECRET = "INFRALAB_EXAM_PROXY_SECRET"
BACKEND_NAMES = (SHARED_SECRET, "INFRALAB_EXAM_PROXY_URL", "INFRALAB_GRADER_ANTHROPIC_KEY", "INFRALAB_PROBLEMS_DIR")


def _compose() -> dict:
    return yaml.safe_load((REPO_ROOT / "compose.prod.yml").read_text(encoding="utf-8"))


def _env(service: dict) -> dict[str, str]:
    """compose 의 environment(맵 또는 `K=V` 목록)를 dict 로."""

    raw = service.get("environment") or {}
    if isinstance(raw, list):
        out = {}
        for item in raw:
            key, _, value = str(item).partition("=")
            out[key] = value
        return out
    return {str(k): "" if v is None else str(v) for k, v in raw.items()}


def _volume_targets(service: dict) -> list[str]:
    targets = []
    for vol in service.get("volumes") or []:
        if isinstance(vol, dict):
            targets.append(str(vol.get("target", "")))
        else:
            parts = str(vol).split(":")
            if len(parts) >= 2:
                targets.append(parts[1])
    return targets


def test_proxy_service_holds_the_provider_keys_and_the_shared_secret():
    services = _compose()["services"]

    assert "proxy" in services
    env = _env(services["proxy"])
    for name in (*PROVIDER_KEYS, SHARED_SECRET):
        assert name in env, f"proxy 환경에 {name} 가 없다"


def test_backend_gets_the_exam_settings_but_never_the_provider_keys():
    services = _compose()["services"]
    env = _env(services["backend"])

    for name in BACKEND_NAMES:
        assert name in env, f"backend 환경에 {name} 가 없다"
    for key in PROVIDER_KEYS:
        assert key not in env
        assert not any(key in value for value in env.values()), f"backend 환경 값이 {key} 를 끌어온다"
    # 공급사 키는 proxy 밖 어떤 서비스에도 가지 않는다.
    for name, service in services.items():
        if name == "proxy":
            continue
        assert not any(key in str(service.get("environment")) for key in PROVIDER_KEYS), name


def test_backend_problems_dir_is_an_absolute_path_with_a_volume():
    backend = _compose()["services"]["backend"]
    value = _env(backend)["INFRALAB_PROBLEMS_DIR"]

    match = re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-(.+)\}", value)
    path = match.group(1) if match else value
    assert path.startswith("/"), f"INFRALAB_PROBLEMS_DIR 는 컨테이너 안 절대 경로여야 한다 ({value!r})"
    assert path.rstrip("/") in [t.rstrip("/") for t in _volume_targets(backend)]


def test_deploy_doc_names_every_new_setting_and_the_problem_bank():
    doc = (REPO_ROOT / "docs" / "ops" / "deploy.md").read_text(encoding="utf-8")

    for name in (*PROVIDER_KEYS, *BACKEND_NAMES, "github-farrar142", "problems.ref"):
        assert name in doc, f"deploy.md 에 {name} 가 없다"


def test_backend_always_allows_the_host_the_proxy_calls():
    """proxy 는 http://backend:8000 으로 내부 API 를 부른다 — .env 의 도메인 목록과 따로 늘 허용한다(#82)."""

    services = _compose()["services"]
    assert _env(services["proxy"])["INFRALAB_PROXY_BACKEND_URL"] == "http://backend:8000"
    assert _env(services["backend"])["DJANGO_INTERNAL_HOSTS"] == "backend"
