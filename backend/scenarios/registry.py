"""시작 때 읽은 시나리오를 메모리에 든다. 서버가 도는 동안 바뀌지 않는다 — 바꾸려면 재기동."""

from __future__ import annotations

import logging
from pathlib import Path

from django.conf import settings

from .loader import Scenario, load_all, load_hidden

logger = logging.getLogger("scenarios")
_scenarios: dict[str, Scenario] | None = None


def load(root: Path | None = None) -> dict[str, Scenario]:
    global _scenarios
    scenarios = load_all(Path(root or settings.SCENARIOS_DIR))
    problems = Path(settings.PROBLEMS_DIR) if settings.PROBLEMS_DIR else None
    if problems is not None and problems.is_dir() and any(problems.iterdir()):
        scenarios = load_hidden(problems, scenarios)
    else:
        logger.warning("숨은 검사를 건너뛴다 — 문제은행 폴더(PROBLEMS_DIR)가 비었거나 없다: %r", settings.PROBLEMS_DIR)
    _scenarios = scenarios
    return _scenarios


def all_scenarios() -> dict[str, Scenario]:
    if _scenarios is None:
        return load()
    return _scenarios


def get(scenario_id: str) -> Scenario | None:
    return all_scenarios().get(scenario_id)
