"""The pytest plugin of the factory's acceptance probe (.github/factory/probe_pytest.py, #212).

acceptance-probe.sh decides from these rows whether an acceptance test is red on an assertion or its
ticket's stub, or on an error of its own (#194: a yaml ConstructorError). The factory's own tests
replay rows this plugin wrote; this test keeps the plugin writing them.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

FACTORY = Path(__file__).resolve().parents[2] / ".github" / "factory"

SPEC = '''
import pytest
import yaml


def stub():
    raise NotImplementedError("#9")


def test_assert():
    assert 1 == 2


def test_stub():
    stub()


def test_yaml():
    yaml.safe_load("ports: !reset []")


def test_pass():
    assert True


@pytest.fixture
def broken():
    raise KeyError("x")


def test_fixture(broken):
    pass


@pytest.mark.skip(reason="#9")
def test_skipped():
    pass
'''


def _probe(tmp_path: Path) -> list[dict[str, str]]:
    (tmp_path / "test_spec_x.py").write_text(SPEC)
    (tmp_path / "test_spec_broken.py").write_text("from nowhere import thing  # noqa\n")
    out = tmp_path / "rows.jsonl"
    env = {
        **os.environ,
        "PROBE_OUT": str(out),
        "PYTHONPATH": str(FACTORY),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    subprocess.run(
        [sys.executable, "-m", "pytest", "-p", "probe_pytest", "-p", "no:cacheprovider", "-p", "no:django",
         "-q", "--continue-on-collection-errors", "test_spec_x.py", "test_spec_broken.py"],
        cwd=tmp_path, env=env, capture_output=True, check=False, timeout=60,
    )
    return [json.loads(line) for line in out.read_text().splitlines()]


def test_the_plugin_writes_one_row_per_outcome_with_the_exception_type(tmp_path: Path) -> None:
    rows = {r["test"]: (r["when"], r["outcome"], r["type"], r["message"]) for r in _probe(tmp_path)}

    assert rows["test_spec_x.py::test_assert"][:3] == ("call", "failed", "AssertionError")
    assert rows["test_spec_x.py::test_stub"] == ("call", "failed", "NotImplementedError", "#9")
    assert rows["test_spec_x.py::test_yaml"][:3] == ("call", "failed", "ConstructorError")
    assert rows["test_spec_x.py::test_pass"] == ("call", "passed", "", "")
    assert rows["test_spec_x.py::test_fixture"][:3] == ("setup", "failed", "KeyError")
    when, outcome, kind, message = rows["test_spec_broken.py"]
    assert (when, outcome, kind) == ("collect", "failed", "CollectError")
    assert message.startswith("ModuleNotFoundError: No module named 'nowhere'")
    assert "test_spec_x.py::test_skipped" not in rows
