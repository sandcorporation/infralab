"""문제은행 자리 — problems.ref, 숨은 검사 불러오기, 공개 검사와의 분리.

target: backend/tests/test_spec_exam_problems.py
AC: #69: problems.ref 는 40자리 소문자 hex sha 한 줄
AC: #69: PROBLEMS_DIR 의 <id>/hidden.yaml 이 hidden_checks 로 붙는다(공개 checks 는 그대로)
AC: #69: PROBLEMS_DIR 이 비었거나 없는 폴더면 숨은 검사 없이 읽히고 「숨은 검사」 경고가 남는다
AC: #69: 깨진 문제은행 파일(스키마 위반, 공개 검사와 같은 id, 없는 시나리오 폴더)은 ScenarioError
AC: #69: 학생 상세·환경 준비에 숨은 검사가 없고, 제출에 숨은 검사 id 를 더하면 422
AC: #69: 저장소 안 견본 문제은행 폴더가 읽히고 숨은 검사가 하나 이상
AC: #69: 설정 PROBLEMS_DIR 은 INFRALAB_PROBLEMS_DIR 에서 오고 기본은 빈 값

시나리오 로더(`scenarios.loader`)와 레지스트리(`scenarios.registry`)를 직접 부르고, 학생 표면은 HTTP 로 본다.
문제은행은 시험마다 임시 폴더에 만든다(s3-static-site 의 숨은 검사 둘). 레지스트리를 다시 읽은 시험은 끝날 때
원래 설정으로 다시 읽어 다른 시험에 숨은 검사가 새지 않게 한다.
"""

import logging
import re
import runpy
from pathlib import Path

import pytest
from django.conf import settings
from django.test import override_settings

from scenarios import registry
from scenarios.loader import ScenarioError, load_all, load_hidden
from tests.api_helpers import S3, S3_CHECK_IDS, s3_results

REPO_ROOT = Path(__file__).resolve().parents[2]
SETTINGS_FILE = str(REPO_ROOT / "backend" / "config" / "settings.py")
pytestmark = pytest.mark.django_db

HIDDEN_IDS = ["hidden-index-body", "hidden-website-suffix"]

HIDDEN_YAML = """\
checks:
  - id: hidden-index-body
    name: index.html 본문
    hint: index.html 에 내용을 넣는다
    command: aws s3 cp s3://lab-site/index.html - | grep -qi html
    expect: exit_zero
  - id: hidden-website-suffix
    name: 웹사이트 인덱스 문서
    command: aws s3api get-bucket-website --bucket lab-site --query IndexDocument.Suffix --output text
    expect: {equals: index.html}
    timeout_seconds: 20
"""


def _scenarios():
    return load_all(Path(settings.SCENARIOS_DIR))


def _bank(root: Path, files: dict[str, str]) -> Path:
    for scenario_id, body in files.items():
        (root / scenario_id).mkdir(parents=True, exist_ok=True)
        (root / scenario_id / "hidden.yaml").write_text(body, encoding="utf-8")
    return root


@pytest.fixture
def hidden_bank(tmp_path):
    """s3-static-site 에 숨은 검사 둘이 든 문제은행으로 레지스트리를 다시 읽는다."""

    root = _bank(tmp_path / "problems", {S3: HIDDEN_YAML})
    with override_settings(PROBLEMS_DIR=str(root)):
        registry.load()
        yield root
    registry.load()


def _student_in_s3_cohort(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort, student


@pytest.mark.skip(reason="#69")
def test_problems_ref_is_one_line_of_a_forty_hex_sha():
    text = (REPO_ROOT / "problems.ref").read_text(encoding="utf-8")
    lines = text.strip().splitlines()
    assert len(lines) == 1
    assert re.fullmatch(r"[0-9a-f]{40}", lines[0]) is not None


@pytest.mark.skip(reason="#69")
def test_hidden_yaml_attaches_hidden_checks_and_keeps_public_checks(tmp_path):
    scenarios = _scenarios()
    root = _bank(tmp_path, {S3: HIDDEN_YAML})

    out = load_hidden(root, scenarios)

    s3 = out[S3]
    assert [c.id for c in s3.hidden_checks] == HIDDEN_IDS
    assert [c.id for c in s3.checks] == S3_CHECK_IDS
    assert s3.checks == scenarios[S3].checks
    first, second = s3.hidden_checks
    assert first.name == "index.html 본문"
    assert first.expect == {"type": "exit_zero"}
    assert second.expect == {"type": "equals", "value": "index.html"}
    assert second.timeout_seconds == 20
    # 문제은행에 폴더가 없는 시나리오는 숨은 검사가 없다.
    assert all(s.hidden_checks == () for sid, s in out.items() if sid != S3)
    # 원래 dict 의 시나리오는 그대로다(새 dict 를 돌려준다).
    assert scenarios[S3].hidden_checks == ()


@pytest.mark.skip(reason="#69")
def test_registry_load_reads_the_problems_dir_setting(hidden_bank):
    s3 = registry.get(S3)
    assert s3 is not None
    assert [c.id for c in s3.hidden_checks] == HIDDEN_IDS
    assert [c.id for c in s3.checks] == S3_CHECK_IDS


@pytest.mark.parametrize("problems_dir", ["", "/nonexistent/infralab-problems"])
@pytest.mark.skip(reason="#69")
def test_empty_or_missing_problems_dir_loads_without_hidden_checks_and_warns(problems_dir, caplog):
    expected = set(_scenarios())
    caplog.set_level(logging.WARNING, logger="scenarios")
    try:
        with override_settings(PROBLEMS_DIR=problems_dir):
            loaded = registry.load()
    finally:
        registry.load()

    assert set(loaded) == expected
    assert all(s.hidden_checks == () for s in loaded.values())
    warnings = [r for r in caplog.records if r.name == "scenarios" and r.levelno >= logging.WARNING]
    assert any("숨은 검사" in r.getMessage() for r in warnings)


@pytest.mark.parametrize(
    "files",
    [
        # 스키마 위반 — expect 가 없다
        {S3: "checks:\n  - id: hidden-a\n    name: a\n    command: 'true'\n"},
        # 모르는 expect 종류
        {S3: "checks:\n  - id: hidden-a\n    name: a\n    command: 'true'\n    expect: maybe\n"},
        # 공개 검사와 같은 id
        {S3: "checks:\n  - id: bucket-exists\n    name: a\n    command: 'true'\n    expect: exit_zero\n"},
        # 저장소에 없는 시나리오의 폴더
        {"no-such-scenario": HIDDEN_YAML},
    ],
    ids=["missing-expect", "unknown-expect", "public-id", "unknown-scenario"],
)
@pytest.mark.skip(reason="#69")
def test_broken_problem_bank_raises_scenario_error(tmp_path, files):
    root = _bank(tmp_path, files)
    with pytest.raises(ScenarioError):
        load_hidden(root, _scenarios())


@pytest.mark.skip(reason="#69")
def test_student_detail_and_prepare_never_show_hidden_checks(api, hidden_bank):
    cohort, student = _student_in_s3_cohort(api)

    detail = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}", student)
    assert detail.status_code == 200, detail.content
    assert [c["id"] for c in detail.json()["checks"]] == S3_CHECK_IDS
    prepare = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/prepare", student)
    assert prepare.status_code == 200, prepare.content
    listed = api.get(f"/api/cohorts/{cohort['id']}/scenarios", student)
    assert listed.status_code == 200
    assert [s["total"] for s in listed.json()] == [len(S3_CHECK_IDS)]

    for res in (detail, prepare, listed):
        body = res.content.decode()
        for hidden_id in HIDDEN_IDS:
            assert hidden_id not in body
        assert "index.html 본문" not in body


@pytest.mark.skip(reason="#69")
def test_submission_takes_only_public_check_ids(api, hidden_bank):
    cohort, student = _student_in_s3_cohort(api)

    public_only = api.submit(student, cohort["id"], S3, s3_results(set(S3_CHECK_IDS)))
    assert public_only.status_code == 201, public_only.content
    assert public_only.json()["total"] == len(S3_CHECK_IDS)

    extra = [{"id": hid, "name": hid, "pass": True, "output": "", "exit_code": 0} for hid in HIDDEN_IDS]
    with_hidden = api.submit(student, cohort["id"], S3, s3_results(set(S3_CHECK_IDS)) + extra)
    assert with_hidden.status_code == 422


@pytest.mark.skip(reason="#69")
def test_sample_problem_bank_loads_and_has_hidden_checks():
    sample = REPO_ROOT / "problems-sample"
    assert sample.is_dir()

    out = load_hidden(sample, _scenarios())

    with_hidden = {sid: s for sid, s in out.items() if s.hidden_checks}
    assert with_hidden, "견본 문제은행에 숨은 검사가 하나도 없다"
    for s in with_hidden.values():
        public_ids = {c.id for c in s.checks}
        assert public_ids.isdisjoint(c.id for c in s.hidden_checks)


@pytest.mark.skip(reason="#69")
def test_problems_dir_setting_comes_from_env_and_defaults_to_empty(monkeypatch):
    monkeypatch.delenv("INFRALAB_PROBLEMS_DIR", raising=False)
    monkeypatch.delenv("DJANGO_DEBUG", raising=False)
    assert runpy.run_path(SETTINGS_FILE)["PROBLEMS_DIR"] == ""

    monkeypatch.setenv("INFRALAB_PROBLEMS_DIR", "/srv/infralab-problems")
    assert runpy.run_path(SETTINGS_FILE)["PROBLEMS_DIR"] == "/srv/infralab-problems"
