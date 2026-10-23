from __future__ import annotations

from typing import Any

from ninja import Schema

from .ai_rules import build_ai_rules
from .loader import Scenario


class KindRequirementOut(Schema):
    control_planes: int
    workers: int


class RequiresOut(Schema):
    floci: bool
    kind: KindRequirementOut | None


class CheckOut(Schema):
    """에이전트 /api/check 에 그대로 넘기는 검사 정의 전문."""

    id: str
    name: str
    hint: str
    command: str
    timeout_seconds: int
    expect: dict[str, Any]
    #: 「지켜야 할 것」 검사면 true. 점수는 똑같이 센다.
    constraint: bool


class ScenarioSummaryOut(Schema):
    """목록용 — 강사의 선택 화면과 학생의 기수 화면이 쓴다."""

    id: str
    title: str
    requires: RequiresOut
    total: int


class StudentScenarioSummaryOut(ScenarioSummaryOut):
    #: 내 최신 제출의 통과 수. 제출이 없으면 None. (제출은 #10 에서 들어온다)
    passed: int | None = None


class ScenarioDetailOut(ScenarioSummaryOut):
    description: str
    checks: list[CheckOut]
    #: 보조 스크립트 — 파일 이름 → 본문. 에이전트가 workstation 에 넣는다.
    scripts: dict[str, str]


class OpenScenariosIn(Schema):
    scenario_ids: list[str]


def summary(s: Scenario) -> dict:
    return {"id": s.id, "title": s.title, "requires": s.requires.as_dict(), "total": len(s.checks)}


def detail(s: Scenario) -> dict:
    return {
        **summary(s),
        "description": s.description,
        "checks": s.check_definitions(),
        "scripts": s.check_scripts(),
    }


class SetupOut(Schema):
    """고장 내기 — 에이전트 /api/setup 의 setup 칸에 그대로 들어간다."""

    command: str
    #: 시나리오 디렉터리의 보조 스크립트 전부(setup 이 부를 수 있다).
    scripts: dict[str, str]
    timeout_seconds: int


class PrepareOut(Schema):
    """「환경 준비」 전용 — 학생 상세에는 싣지 않는 setup 이 여기서만 나간다."""

    scenario_id: str
    setup: SetupOut | None
    setup_reset: str
    kind: KindRequirementOut | None
    ai_rules: str


def prepare(s: Scenario) -> dict:
    return {
        "scenario_id": s.id,
        "setup": (
            {"command": s.setup, "scripts": dict(s.scripts), "timeout_seconds": s.setup_timeout_seconds}
            if s.setup is not None
            else None
        ),
        "setup_reset": s.setup_reset,
        "kind": s.requires.kind.as_dict() if s.requires.kind else None,
        "ai_rules": build_ai_rules(s),
    }
