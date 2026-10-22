"""시나리오 YAML 스키마 — 저장소의 모든 시나리오가 읽히고, 잘못 쓴 것은 명확한 오류로 걸린다.

이음새는 `scenarios.loader` 의 공개 함수다(HTTP 표면은 뒤 티켓에서 이 결과를 그대로 싣는다).
"""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest
from django.conf import settings

from scenarios.loader import ScenarioError, load_all, load_scenario

REPO_SCENARIOS = Path(settings.SCENARIOS_DIR)


def test_every_scenario_in_the_repo_is_valid():
    scenarios = load_all(REPO_SCENARIOS)
    assert "s3-static-site" in scenarios
    for scenario in scenarios.values():
        assert scenario.checks, scenario.id
        for check in scenario.checks:
            assert check.expect["type"] in {"exit_zero", "equals", "contains", "regex", "jsonpath"}


def test_s3_static_site_matches_the_poc_checks():
    s = load_scenario(REPO_SCENARIOS / "s3-static-site")
    assert s.title == "S3 정적 사이트"
    assert s.requires.floci is True and s.requires.kind is None
    assert [c.id for c in s.checks] == ["bucket-exists", "versioning-enabled", "index-uploaded", "website-configured"]
    assert s.checks[1].expect == {"type": "equals", "value": "Enabled"}
    assert all(c.hint for c in s.checks)
    assert "lab-site" in s.description


def test_check_definitions_are_what_the_agent_receives():
    s = load_scenario(REPO_SCENARIOS / "s3-static-site")
    defs = s.check_definitions()
    assert defs[0] == {
        "id": "bucket-exists",
        "name": "버킷 lab-site 존재",
        "hint": defs[0]["hint"],
        "command": "aws s3api head-bucket --bucket lab-site",
        "timeout_seconds": 30,
        "expect": {"type": "exit_zero"},
    }


# ---------- 잘못 쓴 YAML ----------


def _write(tmp_path: Path, scenario_id: str, body: str, scripts: dict[str, str] | None = None) -> Path:
    d = tmp_path / scenario_id
    d.mkdir()
    (d / "scenario.yaml").write_text(textwrap.dedent(body), encoding="utf-8")
    for name, content in (scripts or {}).items():
        (d / name).write_text(content, encoding="utf-8")
    return d


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


def test_minimal_valid_scenario_loads_with_defaults(tmp_path):
    s = load_scenario(_write(tmp_path, "demo", VALID))
    assert s.requires.floci is False and s.requires.kind is None
    assert s.checks[0].hint == "" and s.checks[0].timeout_seconds == 30
    assert s.scripts == {}


@pytest.mark.parametrize(
    "body, message",
    [
        (VALID.replace("    title: 데모\n", ""), "`title` 가 없다"),
        (VALID.replace("expect: exit_zero", "expect: always_pass"), "expect 종류를 모른다"),
        (VALID.replace("expect: exit_zero", "expect: {equals: a, contains: b}"), "키 하나짜리"),
        (VALID.replace("expect: exit_zero", "expect: {regex: '('}"), "정규식이 아니다"),
        (VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: .a}}"), "정확히 하나"),
        (VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: .a, min: two}}"), "숫자여야"),
        (VALID + "    extra: 1\n", "모르는 필드"),
        (VALID.replace("id: demo", "id: Demo"), "소문자"),
        (VALID.replace("id: ok", "id: Ok"), "소문자"),
        (VALID.replace("    checks:", "    requires: {kind: {workers: 99}}\n    checks:"), "0..5"),
        (VALID.replace("expect: exit_zero", "expect: exit_zero\n        timeout_seconds: 0"), "1..300"),
        # YAML 1.1 이 바꿔 버리는 스칼라 — yes→True, 1.10→1.1. 따옴표를 요구한다.
        (VALID.replace("expect: exit_zero", "expect: {equals: yes}"), "따옴표"),
        (VALID.replace("expect: exit_zero", "expect: {contains: 1.10}"), "따옴표"),
        (VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: .a, equals: yes}}"), "따옴표"),
        # Go RE2 가 거부하는 문법
        (VALID.replace("expect: exit_zero", "expect: {regex: '(?=.*Ready)'}"), "RE2"),
        (VALID.replace("expect: exit_zero", "expect: {regex: '(a)\\\\1'}"), "RE2"),
        # 에이전트가 지원하는 경로 문법만
        (VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: 'status.ready', min: 1}}"), "꼴이어야"),
        (VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: '$.items[?(@.x)]', min: 1}}"), "꼴이어야"),
        # 같은 맵에 키가 두 번
        (VALID.replace("title: 데모", "title: 데모\n    title: 또"), "두 번"),
    ],
)


def test_broken_yaml_is_rejected_with_the_reason(tmp_path, body, message):
    with pytest.raises(ScenarioError, match=message):
        load_scenario(_write(tmp_path, "demo", body))


def test_integer_expectations_are_kept_as_text(tmp_path):
    s = load_scenario(_write(tmp_path, "demo", VALID.replace("expect: exit_zero", "expect: {equals: 2}")))
    assert s.checks[0].expect == {"type": "equals", "value": "2"}


def test_jsonpath_subset_is_accepted(tmp_path):
    body = VALID.replace("expect: exit_zero", "expect: {jsonpath: {path: '.items[0].status.readyReplicas', min: 2}}")
    s = load_scenario(_write(tmp_path, "demo", body))
    assert s.checks[0].expect == {"type": "jsonpath", "path": ".items[0].status.readyReplicas", "min": 2}


def test_non_utf8_script_is_a_scenario_error(tmp_path):
    d = _write(tmp_path, "demo", VALID)
    (d / "bad.sh").write_bytes(b"\xff\xfe echo cp949")
    with pytest.raises(ScenarioError, match="UTF-8"):
        load_scenario(d)


def test_underscore_directories_are_not_scenarios_but_others_must_be(tmp_path):
    _write(tmp_path, "demo", VALID)
    (tmp_path / "_shared").mkdir()
    assert list(load_all(tmp_path)) == ["demo"]
    (tmp_path / "typo-dir").mkdir()
    with pytest.raises(ScenarioError, match="typo-dir"):
        load_all(tmp_path)


def test_duplicate_check_ids_are_rejected(tmp_path):
    body = VALID + "      - id: ok\n        name: 또\n        command: \"true\"\n        expect: exit_zero\n"
    with pytest.raises(ScenarioError, match="겹친다"):
        load_scenario(_write(tmp_path, "demo", body))


def test_id_must_match_the_directory_name(tmp_path):
    with pytest.raises(ScenarioError, match="디렉터리 이름"):
        load_scenario(_write(tmp_path, "other", VALID))


def test_one_broken_scenario_fails_the_whole_load(tmp_path):
    _write(tmp_path, "demo", VALID)
    _write(tmp_path, "broken", VALID.replace("id: demo", "id: broken").replace("expect: exit_zero", "expect: nope"))
    with pytest.raises(ScenarioError, match="broken"):
        load_all(tmp_path)


def test_scripts_in_the_directory_are_loaded_with_their_bodies(tmp_path):
    d = _write(
        tmp_path,
        "demo",
        VALID.replace("command: \"true\"", "command: bash check-nginx.sh"),
        scripts={"check-nginx.sh": "#!/bin/sh\ncurl -sf http://10.0.0.5/\n"},
    )
    s = load_scenario(d)
    assert s.scripts == {"check-nginx.sh": "#!/bin/sh\ncurl -sf http://10.0.0.5/\n"}


def test_description_file_is_read_from_the_same_directory(tmp_path):
    d = _write(tmp_path, "demo", VALID.replace("description: 설명", "description_file: README.md"))
    (d / "README.md").write_text("# 제목\n본문", encoding="utf-8")
    assert load_scenario(d).description == "# 제목\n본문"
