"""cohorts 와 다른 앱(scenarios 등)이 함께 쓰는 조회 — 비공개 헬퍼를 앱 경계 너머로 끌어가지 않게 여기 둔다."""

from __future__ import annotations

from django.http import HttpRequest
from ninja.errors import HttpError

from scenarios import registry
from scenarios.loader import Scenario

from .models import Cohort, Membership


def my_membership(request: HttpRequest, cohort_id: int) -> Membership:
    """요청한 사용자의 이 기수 참여. 없으면 404 — 참여하지 않은 기수는 존재 여부도 알리지 않는다."""

    m = Membership.objects.filter(user=request.auth, cohort_id=cohort_id).select_related("cohort").first()
    if m is None:
        raise HttpError(404, "참여하지 않은 기수입니다.")
    return m


def open_scenario_ids(cohort: Cohort) -> list[str]:
    """기수에 열어 둔 시나리오 id 중 저장소에 실제로 있는 것만, 저장한 순서로. 강사·학생 표면이 같은 목록을 본다
    — 저장소에서 사라진 id 가 한쪽에만 보이면 강사가 정리할 길이 없다."""

    known = registry.all_scenarios()
    return [sid for sid in (cohort.open_scenario_ids or []) if sid in known]


def open_scenarios(cohort: Cohort) -> list[Scenario]:
    known = registry.all_scenarios()
    return [known[sid] for sid in open_scenario_ids(cohort)]
