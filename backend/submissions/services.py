"""다른 앱이 쓰는 제출 조회. 「최신」은 어디서나 id 가 큰 것이다(시계가 아니라 저장 순서)."""

from __future__ import annotations

from django.db.models import Max

from cohorts.models import Membership
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


def passed_against(submission: Submission, scenario: Scenario) -> int:
    """제출의 통과 수를 지금 시나리오의 검사 id 에 맞춰 다시 센다 — 검사 정의가 바뀐 뒤 옛 제출도 n/현재 total 로 읽힌다."""

    ids = {c.id for c in scenario.checks}
    return sum(1 for r in submission.results if r.get("pass") and r.get("check_id") in ids)
