"""공유 검사 스크립트(`scenarios/_shared/`)는 로더가 모든 시나리오의 scripts 에 합친다 — 복사본을 두지 않는다."""

import textwrap
from pathlib import Path

import pytest
from django.conf import settings

from scenarios.loader import ScenarioError, load_all, load_scenario

ROOT = Path(settings.SCENARIOS_DIR)
SHARED = ROOT / "_shared"

VALID = """
    id: demo
    title: 데모
    description: 설명
    checks:
      - id: ok
        name: 되는지
        command: %s
        expect: exit_zero
"""


def _scenario(root: Path, command: str, scripts: dict[str, str] | None = None) -> Path:
    d = root / "demo"
    d.mkdir()
    (d / "scenario.yaml").write_text(textwrap.dedent(VALID % command), encoding="utf-8")
    for name, body in (scripts or {}).items():
        (d / name).write_text(body, encoding="utf-8")
    return d


def test_the_three_shared_scripts_exist_and_are_lf_only():
    names = {p.name for p in SHARED.glob("*.sh")}
    assert {"record-baseline.sh", "check-baseline.sh", "serve-and-curl.sh"} <= names
    for p in SHARED.glob("*.sh"):
        assert b"\r\n" not in p.read_bytes(), f"{p.name} 에 CRLF 가 있다"


def test_no_scenario_directory_keeps_a_copy_of_a_shared_script():
    for original in SHARED.glob("*.sh"):
        assert not [p for p in ROOT.glob(f"*/{original.name}") if p.parent.name != "_shared"], f"{original.name} 사본이 시나리오 디렉터리에 있다 — _shared 만 쓴다"


def test_every_repo_scenario_gets_the_shared_scripts():
    for s in load_all(ROOT).values():
        assert {"record-baseline.sh", "check-baseline.sh", "serve-and-curl.sh"} <= set(s.scripts), s.id


def test_a_copy_next_to_the_scenario_is_rejected(tmp_path):
    shared = tmp_path / "_shared"
    shared.mkdir()
    (shared / "util.sh").write_text("echo a\n", encoding="utf-8")
    d = _scenario(tmp_path, '"true"', {"util.sh": "echo b\n"})
    with pytest.raises(ScenarioError, match="_shared"):
        load_scenario(d)


def test_student_scripts_follow_word_boundaries_and_ignore_comments(tmp_path):
    shared = tmp_path / "_shared"
    shared.mkdir()
    (shared / "check-base.sh").write_text("# record-base.sh 가 남긴 기준과 견준다\necho ok\n", encoding="utf-8")
    (shared / "record-base.sh").write_text("echo record\n", encoding="utf-8")
    (shared / "base.sh").write_text("echo base\n", encoding="utf-8")
    d = _scenario(tmp_path, "check-base.sh")
    s = load_scenario(d)
    # check-base.sh 만 — 주석에 언급된 record-base.sh 도, 이름의 부분 문자열인 base.sh 도 학생 상세에 실리지 않는다.
    assert set(s.check_scripts()) == {"check-base.sh"}
    assert {"record-base.sh", "base.sh", "check-base.sh"} <= set(s.scripts)


def test_scripts_called_from_a_script_body_are_included_even_after_a_slash(tmp_path):
    d = _scenario(
        tmp_path,
        "a.sh",
        {"a.sh": 'source "$(dirname "$0")/lib.sh"\n', "lib.sh": "echo lib\n", "other.sh": "echo other\n"},
    )
    assert set(load_scenario(d).check_scripts()) == {"a.sh", "lib.sh"}


def test_a_check_calling_a_script_that_does_not_exist_is_rejected(tmp_path):
    d = _scenario(tmp_path, "missing-check.sh --flag")
    with pytest.raises(ScenarioError, match="missing-check.sh"):
        load_scenario(d)


def test_a_path_prefixed_sh_name_is_not_a_helper_script_call(tmp_path):
    # /etc/profile.d/java.sh 처럼 경로가 붙은 것은 보조 스크립트 호출이 아니다.
    d = _scenario(tmp_path, "cat /etc/profile.d/java.sh")
    assert load_scenario(d).check_scripts() == {}
