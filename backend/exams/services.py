"""응시(ExamInvite) 의 시간 판정 — 지원자 API(exams.api)와 시나리오·제출 API 가 같은 판정을 쓴다.

마감은 `started_at + 시간 제한`(회차의 지금 시험 설정)이고, 서버 시각으로만 판정한다. 지원자가 「제출하고
끝내기」를 누르면 `finished_at` 이 적히고, 시간이 다 되면 적히지 않아도 끝난 것으로 본다.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from django.utils import timezone
from ninja.errors import HttpError

from cohorts.models import Cohort, Membership
from cohorts.services import open_scenarios
from scenarios.loader import Scenario
from submissions.services import latest_submissions_by_scenario, passed_against

from .models import ExamInvite


def deadline(invite: ExamInvite) -> datetime | None:
    if invite.started_at is None:
        return None
    minutes = int((invite.cohort.exam_settings or {}).get("time_limit_minutes", 0))
    return invite.started_at + timedelta(minutes=minutes)


def ended_at(invite: ExamInvite, now: datetime | None = None) -> datetime | None:
    """응시가 끝난 시각. 「끝내기」를 눌렀으면 그 시각, 아니면 지난 마감, 아직이면 None."""

    if invite.finished_at is not None:
        return invite.finished_at
    end = deadline(invite)
    if end is not None and (now or timezone.now()) >= end:
        return end
    return None


def attempt_status(invite: ExamInvite, now: datetime | None = None) -> str:
    """invited · in_progress · finished (회수 여부는 보지 않는다)."""

    if ended_at(invite, now) is not None:
        return "finished"
    if invite.started_at is not None:
        return "in_progress"
    return "invited"


def remaining_seconds(invite: ExamInvite, now: datetime | None = None) -> int | None:
    end = deadline(invite)
    if end is None:
        return None
    now = now or timezone.now()
    if ended_at(invite, now) is not None:
        return 0
    return max(0, int((end - now).total_seconds()))


def check_attempt(membership: Membership, *, submitting: bool = False) -> None:
    """시험 회차 응시자의 시나리오·제출 문. 시작 전이면 403, 마감 뒤 제출이면 403. 수업 묶음은 그대로 지난다."""

    if membership.cohort.kind != Cohort.Kind.EXAM:
        return
    invite = ExamInvite.objects.filter(membership=membership).select_related("cohort").first()
    if invite is None:
        return
    if invite.revoked_at is not None:
        raise HttpError(403, "회수된 응시 링크입니다.")
    if invite.started_at is None:
        raise HttpError(403, "시험을 시작해야 볼 수 있습니다.")
    if submitting and ended_at(invite) is not None:
        raise HttpError(403, "시험이 마감되었습니다.")


def hidden_scenarios(invite: ExamInvite) -> list[Scenario]:
    """이 응시에서 숨은 검사가 도는 시나리오 — 회차 설정 `hidden_checks` 가 켜져 있고 문제은행에서 읽힌 것만."""

    if not (invite.cohort.exam_settings or {}).get("hidden_checks"):
        return []
    return [s for s in open_scenarios(invite.cohort) if s.hidden_checks]


def score(invite: ExamInvite) -> dict:
    """공개·숨은 점수와 최종 점수. 공개는 열린 시나리오마다 최신 제출(없으면 0, 전체는 지금 정의)."""

    scenarios = open_scenarios(invite.cohort)
    latest = latest_submissions_by_scenario(invite.membership) if invite.membership else {}
    public_passed = sum(passed_against(latest[s.id], s) for s in scenarios if s.id in latest)
    public_total = sum(len(s.checks) for s in scenarios)

    hidden = hidden_scenarios(invite)
    hidden_total = sum(len(s.hidden_checks) for s in hidden)
    hidden_passed = 0
    if not hidden:
        status = "skipped"
    elif invite.final_results_at is None:
        status = "pending"
    else:
        status = "done"
        stored = invite.final_results or {}
        for s in hidden:
            ids = {c.id for c in s.hidden_checks}
            hidden_passed += sum(1 for r in stored.get(s.id, []) if r.get("pass") and r.get("check_id") in ids)

    total = public_total + hidden_total
    if status == "pending" or total == 0:
        percent = None
    else:
        percent = round(100 * (public_passed + hidden_passed) / total)
    return {
        "public_passed": public_passed,
        "public_total": public_total,
        "hidden_passed": hidden_passed,
        "hidden_total": hidden_total,
        "hidden_status": status,
        "final_percent": percent,
    }
