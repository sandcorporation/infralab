"""시나리오 API.

- 강사: 전체 시나리오 목록(선택 화면), 기수에 열어 둘 시나리오 지정
- 학생: 기수의 열린 시나리오 목록(내 통과 수 포함), 시나리오 상세(설명·검사 정의 전문·스크립트)
"""

from __future__ import annotations

from django.http import HttpRequest
from ninja import Router
from ninja.errors import HttpError

from accounts.auth import instructor_auth, jwt_auth
from cohorts.services import managed_cohort, my_membership, open_scenario, open_scenarios
from submissions.services import latest_submissions_by_scenario, passed_against  # noqa: F401 - scenarios → submissions 읽기 의존

from . import registry
from .schemas import (
    OpenScenariosIn,
    PrepareOut,
    ScenarioDetailOut,
    ScenarioSummaryOut,
    StudentScenarioSummaryOut,
    detail,
    prepare,
    summary,
)

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
student_router = Router(tags=["student"], auth=jwt_auth)


@instructor_router.get("/scenarios", response=list[ScenarioSummaryOut])
def list_all_scenarios(request: HttpRequest):
    return [summary(s) for s in registry.all_scenarios().values()]


@instructor_router.put("/cohorts/{cohort_id}/scenarios", response=list[str])
def set_open_scenarios(request: HttpRequest, cohort_id: int, payload: OpenScenariosIn):
    """기수에 열어 둘 시나리오를 통째로 바꾼다. 순서가 학생 화면의 순서다."""

    cohort = managed_cohort(request, cohort_id)
    known = registry.all_scenarios()
    unknown = [sid for sid in payload.scenario_ids if sid not in known]
    if unknown:
        raise HttpError(422, f"없는 시나리오: {', '.join(unknown)}")
    ordered: list[str] = []
    for sid in payload.scenario_ids:
        if sid not in ordered:
            ordered.append(sid)
    cohort.open_scenario_ids = ordered
    cohort.save(update_fields=["open_scenario_ids"])
    return ordered


@student_router.get("/cohorts/{cohort_id}/scenarios", response=list[StudentScenarioSummaryOut])
def my_cohort_scenarios(request: HttpRequest, cohort_id: int):
    m = my_membership(request, cohort_id)
    latest = latest_submissions_by_scenario(m)
    out = []
    for s in open_scenarios(m.cohort):
        sub = latest.get(s.id)
        # 옛 제출의 통과 수를 지금 검사 정의에 맞춰 다시 센다 — 검사가 줄면 4/3 이 되지 않게.
        out.append({**summary(s), "passed": passed_against(sub, s) if sub else None})
    return out


@student_router.get("/cohorts/{cohort_id}/scenarios/{scenario_id}", response=ScenarioDetailOut)
def my_cohort_scenario(request: HttpRequest, cohort_id: int, scenario_id: str):
    m = my_membership(request, cohort_id)
    return detail(open_scenario(m, scenario_id))


@student_router.get("/cohorts/{cohort_id}/scenarios/{scenario_id}/prepare", response=PrepareOut)
def my_cohort_scenario_prepare(request: HttpRequest, cohort_id: int, scenario_id: str):
    """「환경 준비」·「시작」 버튼이 쓰는 응답 — 상세에는 없는 setup·되돌릴 것·AI 규칙 전문."""

    m = my_membership(request, cohort_id)
    return prepare(open_scenario(m, scenario_id))
