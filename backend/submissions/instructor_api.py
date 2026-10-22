"""강사의 제출 조회 — 기수 × 시나리오 격자, 학생의 제출 이력, 제출 상세(증거)."""

from __future__ import annotations

from datetime import datetime

from django.http import HttpRequest
from django.shortcuts import get_object_or_404
from ninja import Router, Schema
from ninja.errors import HttpError

from accounts.auth import instructor_auth
from cohorts.models import Cohort, Membership
from cohorts.services import open_scenarios

from .api import submission_out, summary_out
from .models import Submission
from .schemas import SubmissionOut, SubmissionSummaryOut
from .services import latest_submissions_for_cohort, passed_against

instructor_router = Router(tags=["instructor"], auth=instructor_auth)


class GridScenarioOut(Schema):
    id: str
    title: str
    total: int


class GridCellOut(Schema):
    submission_id: int
    passed: int
    total: int
    submitted_at: datetime
    agent_version: str


class GridRowOut(Schema):
    membership_id: int
    user_id: int
    username: str
    display_name: str
    cells: dict[str, GridCellOut | None]


class GridOut(Schema):
    scenarios: list[GridScenarioOut]
    rows: list[GridRowOut]


@instructor_router.get("/cohorts/{cohort_id}/grid", response=GridOut)
def grid(request: HttpRequest, cohort_id: int):
    """참여자 × 열린 시나리오 × 최신 제출 요약. 제출이 없는 칸은 null. 쿼리 수는 참여자 수와 무관하다."""

    cohort = get_object_or_404(Cohort, pk=cohort_id)
    scenarios = open_scenarios(cohort)
    latest = latest_submissions_for_cohort(cohort)
    rows = []
    for m in cohort.memberships.select_related("user"):
        cells: dict[str, GridCellOut | None] = {}
        for s in scenarios:
            sub = latest.get((m.id, s.id))
            cells[s.id] = (
                None
                if sub is None
                else GridCellOut(
                    submission_id=sub.id,
                    passed=passed_against(sub, s),
                    total=len(s.checks),
                    submitted_at=sub.submitted_at,
                    agent_version=sub.agent_version,
                )
            )
        rows.append(
            GridRowOut(
                membership_id=m.id,
                user_id=m.user_id,
                username=m.user.username,
                display_name=m.user.display_name,
                cells=cells,
            )
        )
    return GridOut(
        scenarios=[GridScenarioOut(id=s.id, title=s.title, total=len(s.checks)) for s in scenarios],
        rows=rows,
    )


@instructor_router.get(
    "/cohorts/{cohort_id}/participants/{membership_id}/scenarios/{scenario_id}/submissions",
    response=list[SubmissionSummaryOut],
)
def participant_history(request: HttpRequest, cohort_id: int, membership_id: int, scenario_id: str):
    """한 학생의 같은 시나리오 제출 이력 — 최신 것부터."""

    if not Membership.objects.filter(pk=membership_id, cohort_id=cohort_id).exists():
        raise HttpError(404, "그 학생은 이 기수에 없습니다.")
    return [summary_out(s) for s in Submission.objects.filter(membership_id=membership_id, scenario_id=scenario_id)]


@instructor_router.get("/submissions/{submission_id}", response=SubmissionOut)
def submission_detail(request: HttpRequest, submission_id: int):
    return submission_out(get_object_or_404(Submission, pk=submission_id))
