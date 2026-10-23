"""AI 규칙의 도구 문장은 시나리오가 요구하는 환경을 따른다."""

from pathlib import Path

from django.conf import settings

from scenarios.ai_rules import build_ai_rules
from scenarios.loader import load_all

SCENARIOS = load_all(Path(settings.SCENARIOS_DIR))


def test_floci_only_scenario_names_floci_and_not_kind():
    rules = build_ai_rules(SCENARIOS["s3-static-site"])
    assert "Floci" in rules and "aws" in rules and "terraform" in rules
    assert "kubectl" not in rules and "kind" not in rules
    assert "80 포트" in rules  # EC2 안 80 포트 안내는 Floci 시나리오만


def test_kind_only_scenario_names_kind_and_not_floci():
    rules = build_ai_rules(SCENARIOS["k8s-basics"])
    assert "kubectl" in rules and "kind" in rules
    assert "Floci" not in rules and "`aws`" not in rules
    assert "80 포트" not in rules


def test_code_project_scenarios_list_build_tools_as_allowed_and_no_infra_tools():
    for sid in ("node-api-repair", "python-api-feature", "java-api-repair"):
        rules = build_ai_rules(SCENARIOS[sid])
        assert "npm" in rules and "pytest" in rules and "./gradlew" in rules, sid
        assert "Floci" not in rules and "kubectl" not in rules and "aws·" not in rules, sid
        assert "80 포트" not in rules, sid
        assert "도구(aws" not in rules, sid


def test_both_environments_name_both():
    rules = build_ai_rules(SCENARIOS["k8s-web-down"])
    assert "kubectl" in rules and "kind" in rules and "Floci" not in rules
