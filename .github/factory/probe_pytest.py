"""pytest plugin of acceptance-probe.sh (#212): one JSON line per test outcome into $PROBE_OUT.

Loaded with `-p probe_pytest` (PYTHONPATH holds .github/factory). Each line is
{"test", "when", "outcome", "type", "message"}: `when` is "collect", "setup", "call" or "teardown",
`type` the exception's class name. acceptance-probe.sh decides which failures are the right kind.
"""

from __future__ import annotations

import json
import os
from collections.abc import Generator

import pytest

_OUT = os.environ.get("PROBE_OUT", "")


def _write(row: dict[str, str]) -> None:
    if not _OUT:
        return
    with open(_OUT, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _error_lines(text: str) -> str:
    """The `E   ...` lines of a pytest traceback (the exception), or its last line."""
    lines = [ln[1:].strip() for ln in text.splitlines() if ln.startswith("E ")]
    if not lines:
        lines = [ln for ln in text.splitlines() if ln.strip()][-1:]
    return " ".join(lines)[:600]


def pytest_collectreport(report: pytest.CollectReport) -> None:
    if report.failed:
        _write(
            {
                "test": report.nodeid,
                "when": "collect",
                "outcome": "failed",
                "type": "CollectError",
                "message": _error_lines(str(report.longrepr)),
            }
        )


@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(
    item: pytest.Item, call: pytest.CallInfo[None]
) -> Generator[None, pytest.TestReport, pytest.TestReport]:
    report = yield
    if report.failed:
        excinfo = call.excinfo
        _write(
            {
                "test": item.nodeid,
                "when": call.when,
                "outcome": "failed",
                "type": excinfo.typename if excinfo else "",
                "message": str(excinfo.value)[:600] if excinfo else "",
            }
        )
    elif report.passed and call.when == "call":
        _write({"test": item.nodeid, "when": "call", "outcome": "passed", "type": "", "message": ""})
    return report
