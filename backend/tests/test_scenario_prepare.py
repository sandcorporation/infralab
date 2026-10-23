"""학생 상세에는 setup 이 없고, 「환경 준비」 전용 API 가 setup·스크립트·되돌릴 것·AI 규칙 전문을 준다."""

from __future__ import annotations

import textwrap

import pytest

from scenarios import registry
from scenarios.loader import load_all

BROKEN = """
id: broken-web
title: 고장 난 웹
description: |
  web 이 응답하게 고친다.
requires:
  floci: true
  kind: {control_planes: 1, workers: 2}
setup: break-it.sh
setup_timeout_seconds: 120
ai_rules: |
  80 포트는 쓸 수 없다. 8080 을 쓴다.
checks:
  - id: responds
    name: web 이 응답한다
    hint: Service 셀렉터를 본다
    command: curl-web.sh
    expect: {contains: ok}
  - id: keeps-deployment
    name: Deployment 를 지우지 않았다
    hint: 지우고 다시 만들지 않는다
    command: kubectl get deploy web -o name --secret-marker-command
    expect: exit_zero
    constraint: true
"""

PLAIN = """
id: plain
title: 그냥 시작
description: 만든다.
requires:
  floci: true
checks:
  - id: only
    name: 버킷이 있다
    hint: aws s3 mb
    command: aws s3api head-bucket --bucket b
    expect: exit_zero
"""


@pytest.fixture
def demo(tmp_path, monkeypatch):
    for sid, body, scripts in (
        ("broken-web", BROKEN, {"break-it.sh": "kubectl scale deploy web --replicas=0\n", "curl-web.sh": "curl -s web\n"}),
        ("plain", PLAIN, {}),
    ):
        d = tmp_path / sid
        d.mkdir()
        (d / "scenario.yaml").write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        for name, content in scripts.items():
            (d / name).write_text(content, encoding="utf-8")
    monkeypatch.setattr(registry, "_scenarios", load_all(tmp_path))


def _setup_class(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], ["broken-web", "plain"])
    return teacher, cohort, student


@pytest.mark.django_db
def test_student_detail_hides_setup_and_carries_constraint_flags(api, demo):
    _, cohort, student = _setup_class(api)
    d = api.get(f"/api/cohorts/{cohort['id']}/scenarios/broken-web", student).json()
    for hidden in ("setup", "setup_reset", "setup_timeout_seconds", "ai_rules"):
        assert hidden not in d
    assert [(c["id"], c["constraint"]) for c in d["checks"]] == [("responds", False), ("keeps-deployment", True)]
    # 검사가 부르는 스크립트만 싣는다 — 고장 내기 본문은 학생 화면에 나오지 않는다.
    assert d["scripts"] == {"curl-web.sh": "curl -s web\n"}
    assert "replicas=0" not in str(d)


@pytest.mark.django_db
def test_prepare_returns_setup_scripts_reset_kind_and_rules(api, demo):
    _, cohort, student = _setup_class(api)
    res = api.get(f"/api/cohorts/{cohort['id']}/scenarios/broken-web/prepare", student)
    assert res.status_code == 200, res.content
    p = res.json()
    assert p["scenario_id"] == "broken-web"
    assert p["setup"] == {
        "command": "break-it.sh",
        "scripts": {"break-it.sh": "kubectl scale deploy web --replicas=0\n", "curl-web.sh": "curl -s web\n"},
        "timeout_seconds": 120,
    }
    assert p["setup_reset"] == "both"
    assert p["kind"] == {"control_planes": 1, "workers": 2}
    rules = p["ai_rules"]
    # 공통 규칙 + 할 일 + 검사 이름·힌트(제약 표시) + 시나리오 추가분
    assert "Floci" in rules and "kind" in rules and "/work" in rules and "docker" in rules
    assert "web 이 응답하게 고친다" in rules
    assert "web 이 응답한다" in rules and "Service 셀렉터를 본다" in rules
    assert "Deployment 를 지우지 않았다" in rules and "지켜야 할 것" in rules
    assert "80 포트는 쓸 수 없다. 8080 을 쓴다." in rules
    # 검사 명령은 규칙 전문에 없다
    assert "secret-marker-command" not in rules and "curl-web.sh" not in rules


@pytest.mark.django_db
def test_prepare_without_setup_still_gives_reset_and_rules(api, demo):
    _, cohort, student = _setup_class(api)
    p = api.get(f"/api/cohorts/{cohort['id']}/scenarios/plain/prepare", student).json()
    assert p["setup"] is None
    assert p["setup_reset"] == "floci" and p["kind"] is None
    assert "버킷이 있다" in p["ai_rules"] and "aws s3 mb" in p["ai_rules"]
    assert "지켜야 할 것" not in p["ai_rules"]


@pytest.mark.django_db
def test_prepare_requires_membership_and_an_open_scenario(api, demo):
    teacher, cohort, student = _setup_class(api)
    outsider = api.login("out")
    path = f"/api/cohorts/{cohort['id']}/scenarios/broken-web/prepare"
    assert api.get(path, outsider).status_code == 404
    assert api.get(path).status_code == 401
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/nope/prepare", student).status_code == 404
    api.open_scenarios(teacher, cohort["id"], ["plain"])
    assert api.get(path, student).status_code == 404


@pytest.mark.django_db
def test_existing_scenarios_prepare_with_a_reset_and_common_rules(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], ["s3-static-site", "k8s-basics"])
    s3 = api.get(f"/api/cohorts/{cohort['id']}/scenarios/s3-static-site/prepare", student).json()
    assert s3["setup"] is None and s3["setup_reset"] == "floci" and s3["kind"] is None
    k8s = api.get(f"/api/cohorts/{cohort['id']}/scenarios/k8s-basics/prepare", student).json()
    assert k8s["setup_reset"] == "kind" and k8s["kind"]["control_planes"] == 1
