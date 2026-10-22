"""시작 때 읽은 시나리오를 메모리에 든다. 서버가 도는 동안 바뀌지 않는다 — 바꾸려면 재기동."""

from __future__ import annotations

from pathlib import Path

from django.conf import settings

from .loader import Scenario, load_all

_scenarios: dict[str, Scenario] | None = None


def load(root: Path | None = None) -> dict[str, Scenario]:
    global _scenarios
    _scenarios = load_all(Path(root or settings.SCENARIOS_DIR))
    return _scenarios


def all_scenarios() -> dict[str, Scenario]:
    if _scenarios is None:
        return load()
    return _scenarios


def get(scenario_id: str) -> Scenario | None:
    return all_scenarios().get(scenario_id)
