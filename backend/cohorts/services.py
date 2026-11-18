"""cohorts 와 다른 앱(scenarios 등)이 함께 쓰는 조회 — 비공개 헬퍼를 앱 경계 너머로 끌어가지 않게 여기 둔다."""

from __future__ import annotations

from django.db.models import QuerySet
from django.http import HttpRequest
from django.shortcuts import get_object_or_404
from ninja.errors import HttpError

from scenarios import registry
from scenarios.loader import Scenario

from orgs.services import my_org_ids

from .models import Cohort, Membership


def managed_cohorts(user) -> QuerySet[Cohort]:
    """내가 담당자인 조직들의 기수. 강사 표면은 기수를 언제나 여기서 찾는다 — 남의 조직 기수는 404.
    연습 묶음은 강사 표면에 나오지 않는다 — 「개인 연습」 조직의 담당자여도 404."""

    return Cohort.objects.filter(org_id__in=my_org_ids(user)).exclude(kind=Cohort.Kind.PRACTICE)


def managed_cohort(request: HttpRequest, cohort_id: int) -> Cohort:
    return get_object_or_404(managed_cohorts(request.auth), pk=cohort_id)


def my_membership(request: HttpRequest, cohort_id: int) -> Membership:
    """요청한 사용자의 이 기수 참여. 없으면 404 — 참여하지 않은 기수는 존재 여부도 알리지 않는다."""

    m = Membership.objects.filter(user=request.auth, cohort_id=cohort_id).select_related("cohort").first()
    if m is None:
        raise HttpError(404, "참여하지 않은 기수입니다.")
    return m


def open_scenario_ids(cohort: Cohort) -> list[str]:
    """기수에 열어 둔 시나리오 id 중 저장소에 실제로 있는 것만, 저장한 순서로. 강사·학생 표면이 같은 목록을 본다
    — 저장소에서 사라진 id 가 한쪽에만 보이면 강사가 정리할 길이 없다. 연습 묶음은 저장소의 모든 시나리오다
    (새 시나리오도 자동으로)."""

    known = registry.all_scenarios()
    if cohort.kind == Cohort.Kind.PRACTICE:
        return list(known)
    return [sid for sid in (cohort.open_scenario_ids or []) if sid in known]


def open_scenarios(cohort: Cohort) -> list[Scenario]:
    known = registry.all_scenarios()
    return [known[sid] for sid in open_scenario_ids(cohort)]


def open_scenario(membership: Membership, scenario_id: str) -> Scenario:
    """참여자의 기수에 열린 시나리오 하나. 없거나 닫혔으면 404 — 상세·제출·이력이 같은 판정을 쓴다."""

    s = registry.get(scenario_id)
    if s is None or scenario_id not in open_scenario_ids(membership.cohort):
        raise HttpError(404, "이 기수에 열리지 않은 시나리오입니다.")
    return s
