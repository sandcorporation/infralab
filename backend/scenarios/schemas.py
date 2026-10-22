from __future__ import annotations

from typing import Any

from ninja import Schema

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
        "scripts": dict(s.scripts),
    }
