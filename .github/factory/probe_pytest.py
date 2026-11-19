"""pytest plugin for acceptance-probe.sh (#492): one JSON line per test outcome to $PROBE_OUT.

Loaded with `-p probe_pytest` (the probe puts this directory on PYTHONPATH). Writes
{"test", "when", "outcome", "type", "message"} for every call phase and for every failed setup,
teardown or collection, so the probe can tell an assertion or a ticket stub from any other error.
"""

import json
import os


def _write(row):
    path = os.environ.get("PROBE_OUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as out:
        out.write(json.dumps(row, ensure_ascii=False) + "\n")


def _error(report):
    """(type, message) of the exception behind a failed report."""
    call = getattr(report, "_probe_excinfo", None)
    if call is not None:
        return call
    longrepr = getattr(report, "longrepr", None)
    crash = getattr(longrepr, "reprcrash", None)
    if crash is not None:
        message = crash.message or ""
        kind, _, rest = message.partition(": ")
        if kind and " " not in kind:
            return kind.rsplit(".", 1)[-1], rest
        return "", message
    return "", str(longrepr or "")


def pytest_runtest_makereport(item, call):
    if call.excinfo is not None:
        item._probe_excinfo = (call.excinfo.type.__name__, str(call.excinfo.value))


def pytest_runtest_logreport(report):
    if report.when != "call" and not report.failed:
        return
    kind, message = ("", "")
    if report.failed or report.skipped:
        kind, message = _error(report)
    _write(
        {
            "test": report.nodeid,
            "when": report.when,
            "outcome": report.outcome,
            "type": kind,
            "message": message,
        }
    )


def pytest_collectreport(report):
    if report.failed:
        kind, message = _error(report)
        _write(
            {
                "test": report.nodeid,
                "when": "collect",
                "outcome": "failed",
                "type": kind or "CollectError",
                "message": message,
            }
        )
