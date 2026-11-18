"""시험 모드 API.

- 강사(/api/instructor/…): 시험 설정(#70), 응시 링크(#70), 임시 토큰 회수(#72), 점수(#74), 감독 기록(#75),
  보고서(#76), 시험 대시보드(#77) — 내가 담당자인 조직의 시험 회차만
- 지원자(/api/exam/{token}…): 응시 상태·enter·start·finish(#71), AI 키 설정(#72), 숨은 검사(#74), 감독 신호(#75)
- AI 프록시 전용(/api/proxy/…): 임시 토큰 확인·기록(#72), 공유 비밀 `EXAM_PROXY_SECRET`
"""

from __future__ import annotations

from django.contrib.auth import get_user, get_user_model, login
from django.db import transaction
from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import check_origin, instructor_auth
from cohorts.api import _cohort_out as cohort_out
from cohorts.api import _cohorts_with_counts as cohorts_with_counts
from cohorts.models import Cohort, Membership
from cohorts.schemas import CohortOut

from . import services
from .models import ExamInvite
from .schemas import ExamInviteIn, ExamInviteOut, ExamSettingsIn, ExamStartIn, ExamStatusOut

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
exam_router = Router(tags=["exam"])
proxy_router = Router(tags=["proxy"])

#: 응시마다 하나씩 만드는 숨은 사용자의 이름 앞부분 — sandcorp 로그인 사용자(`sandcorp:<sub>`)와 겹치지 않는다.
HIDDEN_USER_PREFIX = "exam-invite:"
AUTH_BACKEND = "django.contrib.auth.backends.ModelBackend"


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
    return services.attempt_status(invite)


def _invite_out(invite: ExamInvite) -> ExamInviteOut:
    return ExamInviteOut(
        id=invite.id,
        label=invite.label,
        token=invite.token,
        status=_status(invite),
        created_at=invite.created_at,
        started_at=invite.started_at,
        finished_at=services.ended_at(invite),
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


def _live_invite(token: str) -> ExamInvite:
    """회수되지 않은 응시 링크. 없거나 회수됐으면 404."""

    invite = ExamInvite.objects.select_related("cohort", "membership").filter(token=token, revoked_at=None).first()
    if invite is None:
        raise HttpError(404, "응시 링크가 올바르지 않거나 회수되었습니다.")
    return invite


def _exam_status_out(invite: ExamInvite) -> ExamStatusOut:
    now = timezone.now()
    settings = invite.cohort.exam_settings or {}
    return ExamStatusOut(
        cohort_id=invite.cohort_id,
        cohort_name=invite.cohort.name,
        status=services.attempt_status(invite, now),
        time_limit_minutes=int(settings.get("time_limit_minutes", 0)),
        tools=list(settings.get("tools", [])),
        proctoring=bool(settings.get("proctoring", False)),
        started_at=invite.started_at,
        deadline=services.deadline(invite),
        remaining_seconds=services.remaining_seconds(invite, now),
        server_time=now,
    )


def _candidate_invite(request: HttpRequest, token: str) -> ExamInvite:
    """이 브라우저가 `enter` 한 응시. `enter` 전이면 409, 다른 사람의 세션이면 403."""

    check_origin(request)
    invite = _live_invite(token)
    if invite.membership is None:
        raise HttpError(409, "응시 링크로 먼저 들어오세요.")
    user = get_user(request)
    if not user.is_authenticated:
        raise HttpError(409, "응시 링크로 먼저 들어오세요.")
    if user.pk != invite.membership.user_id:
        raise HttpError(403, "이 응시의 세션이 아닙니다.")
    return invite


@exam_router.get("/exam/{token}", auth=None, response=ExamStatusOut)
def exam_status(request: HttpRequest, token: str):
    return _exam_status_out(_live_invite(token))


@exam_router.post("/exam/{token}/enter", auth=None, response=ExamStatusOut)
def enter_exam(request: HttpRequest, token: str):
    """응시 한 번만을 위한 숨은 사용자로 세션을 연다. 같은 링크는 언제나 같은 사용자·같은 참여다."""

    check_origin(request)
    _live_invite(token)
    User = get_user_model()
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(token=token)
        if invite.membership is None:
            user, created = User.objects.get_or_create(
                username=f"{HIDDEN_USER_PREFIX}{invite.pk}", defaults={"display_name": invite.label}
            )
            if created:
                user.set_unusable_password()
                user.save(update_fields=["password"])
            membership, _ = Membership.objects.get_or_create(user=user, cohort=invite.cohort)
            invite.membership = membership
            invite.save(update_fields=["membership"])
        user = invite.membership.user
    login(request, user, backend=AUTH_BACKEND)
    return _exam_status_out(invite)


@exam_router.post("/exam/{token}/start", auth=None, response=ExamStatusOut)
def start_exam(request: HttpRequest, token: str, payload: ExamStartIn):
    if not payload.consent:
        raise HttpError(422, "안내에 동의해야 시작할 수 있습니다.")
    invite = _candidate_invite(request, token)
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(pk=invite.pk)
        if services.attempt_status(invite) == "finished":
            raise HttpError(409, "이미 끝난 시험입니다.")
        if invite.started_at is None:
            now = timezone.now()
            invite.consented_at = now
            invite.started_at = now
            invite.save(update_fields=["consented_at", "started_at"])
    return _exam_status_out(invite)


@exam_router.post("/exam/{token}/finish", auth=None, response=ExamStatusOut)
def finish_exam(request: HttpRequest, token: str):
    invite = _candidate_invite(request, token)
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(pk=invite.pk)
        if invite.started_at is None:
            raise HttpError(409, "시작하지 않은 시험입니다.")
        if invite.finished_at is None:
            invite.finished_at = services.ended_at(invite) or timezone.now()
            invite.save(update_fields=["finished_at"])
    return _exam_status_out(invite)


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
