"""다른 앱이 쓰는 제출 조회. 「최신」은 어디서나 id 가 큰 것이다(시계가 아니라 저장 순서).

점수는 어디서나 지금 시나리오의 검사 정의에 맞춰 다시 센다(`score`) — 검사 정의가 바뀐 뒤 옛 제출도
n/현재 total 로 읽히고, 격자·이력·상세가 같은 수를 보인다.
"""

from __future__ import annotations

from django.db.models import Max

from cohorts.models import Cohort, Membership
from scenarios import registry
from scenarios.loader import Scenario

from .models import Submission


def latest_submissions_by_scenario(membership: Membership) -> dict[str, Submission]:
    """참여자의 시나리오별 최신 제출. 제출이 없는 시나리오는 빠진다."""

    latest_ids = (
        Submission.objects.filter(membership=membership)
        .values("scenario_id")
        .annotate(latest_id=Max("id"))
        .values_list("latest_id", flat=True)
    )
    return {s.scenario_id: s for s in Submission.objects.filter(id__in=list(latest_ids))}


def latest_submissions_for_cohort(cohort: Cohort) -> dict[tuple[int, str], Submission]:
    """기수 전체의 (참여 id, 시나리오 id) → 최신 제출. 쿼리 두 번 — 격자가 참여자 수만큼 되묻지 않게."""

    latest_ids = (
        Submission.objects.filter(membership__cohort=cohort)
        .values("membership_id", "scenario_id")
        .annotate(latest_id=Max("id"))
        .values_list("latest_id", flat=True)
    )
    return {(s.membership_id, s.scenario_id): s for s in Submission.objects.filter(id__in=list(latest_ids))}


def passed_against(submission: Submission, scenario: Scenario) -> int:
    ids = {c.id for c in scenario.checks}
    return sum(1 for r in submission.results if r.get("pass") and r.get("check_id") in ids)


def score(submission: Submission) -> tuple[int, int]:
    """(통과, 전체). 시나리오가 저장소에 있으면 지금 정의로 다시 세고, 없으면 저장된 값."""

    scenario = registry.get(submission.scenario_id)
    if scenario is None:
        return submission.passed, submission.total
    return passed_against(submission, scenario), len(scenario.checks)
