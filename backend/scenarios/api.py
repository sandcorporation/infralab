"""시나리오 API.

- 강사: 전체 시나리오 목록(선택 화면), 기수에 열어 둘 시나리오 지정
- 학생: 기수의 열린 시나리오 목록(내 통과 수 포함), 시나리오 상세(설명·검사 정의 전문·스크립트)
"""

from __future__ import annotations

from django.http import HttpRequest
from django.shortcuts import get_object_or_404
from ninja import Router
from ninja.errors import HttpError

from accounts.auth import instructor_auth, jwt_auth
from cohorts.models import Cohort
from cohorts.services import my_membership, open_scenario_ids, open_scenarios

from . import registry
from .schemas import OpenScenariosIn, ScenarioDetailOut, ScenarioSummaryOut, StudentScenarioSummaryOut, detail, summary

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
student_router = Router(tags=["student"], auth=jwt_auth)


@instructor_router.get("/scenarios", response=list[ScenarioSummaryOut])
def list_all_scenarios(request: HttpRequest):
    return [summary(s) for s in registry.all_scenarios().values()]


@instructor_router.put("/cohorts/{cohort_id}/scenarios", response=list[str])
def set_open_scenarios(request: HttpRequest, cohort_id: int, payload: OpenScenariosIn):
    """기수에 열어 둘 시나리오를 통째로 바꾼다. 순서가 학생 화면의 순서다."""

    cohort = get_object_or_404(Cohort, pk=cohort_id)
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
    return [{**summary(s), "passed": None} for s in open_scenarios(m.cohort)]


@student_router.get("/cohorts/{cohort_id}/scenarios/{scenario_id}", response=ScenarioDetailOut)
def my_cohort_scenario(request: HttpRequest, cohort_id: int, scenario_id: str):
    m = my_membership(request, cohort_id)
    s = registry.get(scenario_id)
    if s is None or scenario_id not in open_scenario_ids(m.cohort):
        raise HttpError(404, "이 기수에 열리지 않은 시나리오입니다.")
    return detail(s)
