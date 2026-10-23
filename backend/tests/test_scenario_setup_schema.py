"""시나리오 YAML 의 setup · setup_reset · setup_timeout_seconds · constraint · ai_rules 스키마."""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from scenarios.loader import ScenarioError, load_scenario

VALID = """
    id: demo
    title: 데모
    description: 설명
    checks:
      - id: ok
        name: 되는지
        command: "true"
        expect: exit_zero
"""


def _write(tmp_path: Path, scenario_id: str, body: str, scripts: dict[str, str] | None = None) -> Path:
    d = tmp_path / scenario_id
    d.mkdir()
    (d / "scenario.yaml").write_text(textwrap.dedent(body), encoding="utf-8")
    for name, content in (scripts or {}).items():
        (d / name).write_text(content, encoding="utf-8")
    return d


def test_setup_script_reset_timeout_rules_and_constraint_are_read(tmp_path):
    body = VALID.replace(
        "    checks:",
        "    requires: {floci: true, kind: {control_planes: 1, workers: 2}}\n"
        "    setup: break-it.sh\n    setup_timeout_seconds: 90\n    ai_rules: |\n      80 포트를 쓰지 않는다.\n    checks:",
    ).replace("expect: exit_zero", "expect: exit_zero\n        constraint: true")
    s = load_scenario(_write(tmp_path, "demo", body, scripts={"break-it.sh": "echo broken\n"}))
    assert s.setup == "break-it.sh" and s.setup_timeout_seconds == 90
    assert s.setup_reset == "both"  # requires 를 따른다
    assert s.ai_rules.strip() == "80 포트를 쓰지 않는다."
    assert s.checks[0].constraint is True
    assert s.checks[0].as_dict()["constraint"] is True


def test_defaults_follow_requires(tmp_path):
    s = load_scenario(_write(tmp_path, "demo", VALID))
    assert s.setup is None and s.setup_timeout_seconds == 30 and s.ai_rules == ""
    assert s.setup_reset == "none"
    assert s.checks[0].constraint is False and s.checks[0].as_dict()["constraint"] is False
    floci = VALID.replace("id: demo", "id: f").replace("    checks:", "    requires: {floci: true}\n    checks:")
    assert load_scenario(_write(tmp_path, "f", floci)).setup_reset == "floci"
    kind = VALID.replace("id: demo", "id: k").replace("    checks:", "    requires: {kind: {workers: 1}}\n    checks:")
    assert load_scenario(_write(tmp_path, "k", kind)).setup_reset == "kind"


def test_explicit_setup_reset_overrides_requires(tmp_path):
    body = VALID.replace("    checks:", "    requires: {floci: true}\n    setup_reset: none\n    checks:")
    assert load_scenario(_write(tmp_path, "demo", body)).setup_reset == "none"


@pytest.mark.parametrize(
    "extra, message",
    [
        ("    setup: missing.sh\n", "missing.sh"),  # 디렉터리에 없는 스크립트
        ("    setup: ''\n", "setup"),
        ("    setup: 3\n", "setup"),
        ("    setup_reset: everything\n", "setup_reset"),
        ("    setup_reset: kind\n", "requires.kind"),  # kind 구성 없이 kind 를 되돌릴 수 없다
        ("    setup_timeout_seconds: 5\n", "setup 없이"),
        ("    setup: echo hi\n    setup_timeout_seconds: 0\n", "1..300"),
        ("    setup: echo hi\n    setup_timeout_seconds: 301\n", "1..300"),
        ("    ai_rules: 3\n", "ai_rules"),
    ],
)
def test_broken_setup_fields_are_rejected(tmp_path, extra, message):
    body = VALID.replace("    checks:", extra + "    checks:")
    with pytest.raises(ScenarioError, match=message):
        load_scenario(_write(tmp_path, "demo", body))


@pytest.mark.parametrize("value", ["yes please", '"true"', "1"])
def test_constraint_must_be_a_bool(tmp_path, value):
    body = VALID.replace("expect: exit_zero", f"expect: exit_zero\n        constraint: {value}")
    with pytest.raises(ScenarioError, match="constraint"):
        load_scenario(_write(tmp_path, "demo", body))


def test_inline_setup_command_is_not_treated_as_a_script_name(tmp_path):
    body = VALID.replace("    checks:", "    setup: kubectl apply -f x.yaml\n    checks:")
    assert load_scenario(_write(tmp_path, "demo", body)).setup == "kubectl apply -f x.yaml"
