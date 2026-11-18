"""시험 모드 API.

- 강사(/api/instructor/…): 시험 설정(#70), 응시 링크(#70), 임시 토큰 회수(#72), 점수(#74), 감독 기록(#75),
  보고서(#76), 시험 대시보드(#77) — 내가 담당자인 조직의 시험 회차만
- 지원자(/api/exam/{token}…): 응시 상태·enter·start·finish(#71), AI 키 설정(#72), 숨은 검사(#74), 감독 신호(#75)
- AI 프록시 전용(/api/proxy/…): 임시 토큰 확인·기록(#72), 공유 비밀 `EXAM_PROXY_SECRET`
"""

from __future__ import annotations

from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import instructor_auth
from cohorts.api import _cohort_out as cohort_out
from cohorts.api import _cohorts_with_counts as cohorts_with_counts
from cohorts.models import Cohort
from cohorts.schemas import CohortOut

from .models import ExamInvite
from .schemas import ExamInviteIn, ExamInviteOut, ExamSettingsIn

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
exam_router = Router(tags=["exam"])
proxy_router = Router(tags=["proxy"])


# ---------- 강사 ----------


def _exam_cohort(request: HttpRequest, cohort_id: int) -> Cohort:
    """내 조직의 시험 회차. 남의 조직이면 404, 수업 묶음이면 422."""

    cohort = get_object_or_404(cohorts_with_counts(request.auth), pk=cohort_id)
    if cohort.kind != Cohort.Kind.EXAM:
        raise HttpError(422, "시험 회차가 아닙니다.")
    return cohort


def _status(invite: ExamInvite) -> str:
    if invite.revoked_at is not None:
        return "revoked"
    if invite.finished_at is not None:
        return "finished"
    if invite.started_at is not None:
        return "in_progress"
    return "invited"


def _invite_out(invite: ExamInvite) -> ExamInviteOut:
    return ExamInviteOut(
        id=invite.id,
        label=invite.label,
        token=invite.token,
        status=_status(invite),
        created_at=invite.created_at,
        started_at=invite.started_at,
        finished_at=invite.finished_at,
    )


@instructor_router.put("/cohorts/{cohort_id}/exam-settings", response=CohortOut)
def put_exam_settings(request: HttpRequest, cohort_id: int, payload: ExamSettingsIn):
    cohort = _exam_cohort(request, cohort_id)
    cohort.exam_settings = payload.normalized()
    cohort.save(update_fields=["exam_settings"])
    return cohort_out(get_object_or_404(cohorts_with_counts(request.auth), pk=cohort_id))


@instructor_router.post("/cohorts/{cohort_id}/exam-invites", response={201: ExamInviteOut})
def create_exam_invite(request: HttpRequest, cohort_id: int, payload: ExamInviteIn):
    cohort = _exam_cohort(request, cohort_id)
    if not cohort.exam_settings:
        raise HttpError(409, "시험 설정을 먼저 저장하세요.")
    return Status(201, _invite_out(ExamInvite.objects.create(cohort=cohort, label=payload.label)))


@instructor_router.get("/cohorts/{cohort_id}/exam-invites", response=list[ExamInviteOut])
def list_exam_invites(request: HttpRequest, cohort_id: int):
    cohort = _exam_cohort(request, cohort_id)
    return [_invite_out(i) for i in cohort.exam_invites.all()]


@instructor_router.delete("/cohorts/{cohort_id}/exam-invites/{invite_id}", response={204: None})
def revoke_exam_invite(request: HttpRequest, cohort_id: int, invite_id: int):
    cohort = _exam_cohort(request, cohort_id)
    invite = get_object_or_404(cohort.exam_invites, pk=invite_id)
    if invite.revoked_at is None:
        invite.revoked_at = timezone.now()
        invite.save(update_fields=["revoked_at"])
    return HttpResponse(status=204)


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/ai-token/revoke")
def revoke_ai_token(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#72")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/score")
def exam_score(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#74")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/events")
def exam_events(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#75")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/report")
def exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#76")


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/grade")
def grade_exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#76")


@instructor_router.patch("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/rubric/{key}")
def edit_rubric_item(request: HttpRequest, cohort_id: int, invite_id: int, key: str):
    raise NotImplementedError("#76")


@instructor_router.get("/exam-dashboard")
def exam_dashboard(request: HttpRequest):
    raise NotImplementedError("#77")


# ---------- 지원자 ----------


@exam_router.get("/exam/{token}", auth=None)
def exam_status(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/enter", auth=None)
def enter_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/start", auth=None)
def start_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/finish", auth=None)
def finish_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.get("/exam/{token}/ai-config", auth=None)
def exam_ai_config(request: HttpRequest, token: str):
    raise NotImplementedError("#72")


@exam_router.get("/exam/{token}/final-checks", auth=None)
def exam_final_checks(request: HttpRequest, token: str):
    raise NotImplementedError("#74")


@exam_router.post("/exam/{token}/final-results", auth=None)
def exam_final_results(request: HttpRequest, token: str):
    raise NotImplementedError("#74")


@exam_router.post("/exam/{token}/events", auth=None)
def exam_event(request: HttpRequest, token: str):
    raise NotImplementedError("#75")


# ---------- AI 프록시 전용 ----------


@proxy_router.post("/proxy/authorize", auth=None)
def proxy_authorize(request: HttpRequest):
    raise NotImplementedError("#72")


@proxy_router.post("/proxy/exchanges", auth=None)
def proxy_exchanges(request: HttpRequest):
    raise NotImplementedError("#72")
