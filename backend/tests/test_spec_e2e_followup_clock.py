"""e2e 전용 시계 당기기 — 설정 `E2E_HOOKS_ENABLED` 와 관리 명령 `e2e_expire_exam`.

target: backend/tests/test_spec_e2e_followup_clock.py
AC: #194: E2E_HOOKS_ENABLED 는 DEBUG 이고 INFRALAB_E2E_HOOKS 가 참일 때만 참 — 기본 거짓, 운영 설정(DJANGO_DEBUG=false)에서는 INFRALAB_E2E_HOOKS=1 이어도 거짓
AC: #194: docker/compose.e2e.yaml 의 backend 만 INFRALAB_E2E_HOOKS=1, compose.dev.yaml·compose.prod.yml 의 backend 는 주지 않는다
AC: #194: e2e_expire_exam <cohort_id> 는 그 회차의 응시 중인 응시를 마감이 지난 꼴로(finished·remaining_seconds 0·제출 403), 시작 전·다른 회차는 그대로
AC: #194: E2E_HOOKS_ENABLED 가 거짓이면 CommandError(INFRALAB_E2E_HOOKS)로 멈추고 아무것도 바꾸지 않는다, 없는 회차도 CommandError

마감 e2e 가 1분을 기다리지 않도록 서버 시계를 당기는 길이, e2e 스택에서만 켜지고 운영 설정에서는 꺼져 있는지 본다.
설정은 test_deploy_settings.py 처럼 settings.py 를 지금 환경에서 새로 실행해 보고, 명령의 효과는 지원자가 보는
응시 상태 API(GET /api/exam/{token})와 제출 API 로 본다.
"""

import runpy
from pathlib import Path

import pytest
import yaml
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import Client, override_settings

from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

BACKEND = Path(__file__).resolve().parent.parent
SETTINGS_FILE = str(BACKEND / "config" / "settings.py")
REPO = BACKEND.parent

EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": True,
    "hidden_checks": False,
    "ai_token_limit": 100000,
}


def _fresh_settings(monkeypatch: pytest.MonkeyPatch, **env: str) -> dict[str, object]:
    for name in ("DJANGO_DEBUG", "DJANGO_SECRET_KEY", "INFRALAB_E2E_HOOKS"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    return runpy.run_path(SETTINGS_FILE)


def _backend_env(compose_file: Path) -> dict:
    doc = yaml.safe_load(compose_file.read_text(encoding="utf-8"))
    return doc["services"]["backend"].get("environment") or {}


# ---------- 설정 ----------


@pytest.mark.skip(reason="#194")
def test_e2e_hooks_are_off_by_default(monkeypatch):
    s = _fresh_settings(monkeypatch)
    assert s["E2E_HOOKS_ENABLED"] is False


@pytest.mark.skip(reason="#194")
def test_e2e_hooks_turn_on_only_with_debug_and_the_env(monkeypatch):
    s = _fresh_settings(monkeypatch, DJANGO_DEBUG="true", INFRALAB_E2E_HOOKS="1")
    assert s["E2E_HOOKS_ENABLED"] is True
    s = _fresh_settings(monkeypatch, DJANGO_DEBUG="true", INFRALAB_E2E_HOOKS="0")
    assert s["E2E_HOOKS_ENABLED"] is False


@pytest.mark.skip(reason="#194")
def test_production_settings_keep_e2e_hooks_off_even_with_the_env(monkeypatch):
    s = _fresh_settings(
        monkeypatch,
        DJANGO_DEBUG="false",
        DJANGO_SECRET_KEY="test-only-secret",
        INFRALAB_E2E_HOOKS="1",
    )
    assert s["DEBUG"] is False
    assert s["E2E_HOOKS_ENABLED"] is False


@pytest.mark.skip(reason="#194")
def test_only_the_e2e_compose_turns_the_hooks_on():
    assert str(_backend_env(REPO / "docker" / "compose.e2e.yaml").get("INFRALAB_E2E_HOOKS")) == "1"
    assert "INFRALAB_E2E_HOOKS" not in _backend_env(REPO / "docker" / "compose.dev.yaml")
    assert "INFRALAB_E2E_HOOKS" not in _backend_env(REPO / "compose.prod.yml")


# ---------- 관리 명령 ----------


def _exam(api, teacher, name="백엔드 1회차"):
    res = api.post("/api/instructor/cohorts", {"name": name, "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    cohort = res.json()
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", EXAM_SETTINGS, teacher)
    assert res.status_code == 200, res.content
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort


def _invite(api, teacher, cohort_id, label):
    res = api.post(f"/api/instructor/cohorts/{cohort_id}/exam-invites", {"label": label}, teacher)
    assert res.status_code == 201, res.content
    return res.json()


def _started(api, teacher, cohort_id, label) -> tuple[dict, Session]:
    invite = _invite(api, teacher, cohort_id, label)
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    res = api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand)
    assert res.status_code == 200, res.content
    return invite, cand


def _status(cand: Session, invite: dict) -> dict:
    res = cand.client.get(f"/api/exam/{invite['token']}")
    assert res.status_code == 200, res.content
    return res.json()


@pytest.mark.django_db
@pytest.mark.skip(reason="#194")
def test_expire_exam_closes_started_attempts_of_that_cohort(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _started(api, teacher, cohort["id"], "지원자 A")
    assert _status(cand, invite)["status"] == "in_progress"

    with override_settings(E2E_HOOKS_ENABLED=True):
        call_command("e2e_expire_exam", cohort["id"])

    status = _status(cand, invite)
    assert status["status"] == "finished"
    assert status["remaining_seconds"] == 0
    assert api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS))).status_code == 403


@pytest.mark.django_db
@pytest.mark.skip(reason="#194")
def test_expire_exam_leaves_unstarted_attempts_and_other_cohorts_alone(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    other = _exam(api, teacher, name="백엔드 2회차")
    _started(api, teacher, cohort["id"], "지원자 A")
    waiting = _invite(api, teacher, cohort["id"], "지원자 B")
    elsewhere, other_cand = _started(api, teacher, other["id"], "지원자 C")

    with override_settings(E2E_HOOKS_ENABLED=True):
        call_command("e2e_expire_exam", cohort["id"])

    status = Client().get(f"/api/exam/{waiting['token']}").json()
    assert status["status"] == "invited"
    status = _status(other_cand, elsewhere)
    assert status["status"] == "in_progress"
    assert status["remaining_seconds"] > 0
    res = api.submit(other_cand, other["id"], S3, s3_results({"bucket-exists"}))
    assert res.status_code == 201, res.content


@pytest.mark.django_db
@pytest.mark.skip(reason="#194")
def test_expire_exam_refuses_when_the_hooks_are_off(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _started(api, teacher, cohort["id"], "지원자 A")
    before = _status(cand, invite)

    with override_settings(E2E_HOOKS_ENABLED=False), pytest.raises(CommandError, match="INFRALAB_E2E_HOOKS"):
        call_command("e2e_expire_exam", cohort["id"])

    after = _status(cand, invite)
    assert after["status"] == "in_progress"
    assert after["started_at"] == before["started_at"]
    assert after["remaining_seconds"] > 0


@pytest.mark.django_db
@pytest.mark.skip(reason="#194")
def test_expire_exam_refuses_an_unknown_cohort(api):
    with override_settings(E2E_HOOKS_ENABLED=True), pytest.raises(CommandError):
        call_command("e2e_expire_exam", 987654)
