"""기수·가입 API.

- 강사(/api/instructor/cohorts…): 기수 만들기·목록·이름 변경·참여자 목록
- 가입(/api/join/{token}): 미리보기(공개), 참여(로그인 필요)
- 학생(/api/cohorts): 내 기수 목록
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.db.models import Count
from django.http import HttpRequest
from django.shortcuts import get_object_or_404
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import instructor_auth, jwt_auth

from .models import Cohort, Membership
from .schemas import (
    CohortCreateIn,
    CohortOut,
    CohortUpdateIn,
    JoinOut,
    JoinPreviewOut,
    MyCohortOut,
    ParticipantOut,
)

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
join_router = Router(tags=["join"])
student_router = Router(tags=["student"], auth=jwt_auth)


def _cohort_out(c: Cohort) -> CohortOut:
    count = getattr(c, "member_count", None)
    if count is None:
        count = c.memberships.count()
    return CohortOut(
        id=c.id,
        name=c.name,
        join_token=c.join_token,
        join_open=c.join_open,
        archived=c.archived,
        open_scenario_ids=list(c.open_scenario_ids or []),
        member_count=count,
        created_at=c.created_at,
    )


# ---------- 강사 ----------


@instructor_router.post("/cohorts", response={201: CohortOut})
def create_cohort(request: HttpRequest, payload: CohortCreateIn):
    cohort = Cohort.objects.create(name=payload.name)
    return Status(201, _cohort_out(cohort))


@instructor_router.get("/cohorts", response=list[CohortOut])
def list_cohorts(request: HttpRequest):
    qs = Cohort.objects.annotate(member_count=Count("memberships"))
    return [_cohort_out(c) for c in qs]


@instructor_router.get("/cohorts/{cohort_id}", response=CohortOut)
def get_cohort(request: HttpRequest, cohort_id: int):
    return _cohort_out(get_object_or_404(Cohort, pk=cohort_id))


@instructor_router.patch("/cohorts/{cohort_id}", response=CohortOut)
def update_cohort(request: HttpRequest, cohort_id: int, payload: CohortUpdateIn):
    cohort = get_object_or_404(Cohort, pk=cohort_id)
    if payload.name is not None:
        cohort.name = payload.name
        cohort.save(update_fields=["name"])
    return _cohort_out(cohort)


@instructor_router.get("/cohorts/{cohort_id}/participants", response=list[ParticipantOut])
def list_participants(request: HttpRequest, cohort_id: int):
    cohort = get_object_or_404(Cohort, pk=cohort_id)
    return [
        ParticipantOut(
            membership_id=m.id,
            user_id=m.user_id,
            username=m.user.username,
            display_name=m.user.display_name,
            joined_at=m.joined_at,
        )
        for m in cohort.memberships.select_related("user")
    ]


# ---------- 가입 ----------


def _cohort_by_token(token: str) -> Cohort:
    cohort = Cohort.objects.filter(join_token=token).first()
    if cohort is None:
        raise HttpError(404, "가입 링크가 올바르지 않습니다. 강사에게 새 링크를 받으세요.")
    return cohort


@join_router.get("/join/{token}", response=JoinPreviewOut, auth=None)
def preview_join(request: HttpRequest, token: str):
    c = _cohort_by_token(token)
    return JoinPreviewOut(cohort_id=c.id, name=c.name, join_open=c.join_open and not c.archived)


@join_router.post("/join/{token}", response=JoinOut, auth=jwt_auth)
def join(request: HttpRequest, token: str):
    c = _cohort_by_token(token)
    existing = Membership.objects.filter(user=request.auth, cohort=c).first()
    if existing is not None:
        return JoinOut(cohort_id=c.id, name=c.name, created=False)
    if not c.join_open or c.archived:
        raise HttpError(403, "이 기수는 가입이 닫혔습니다.")
    try:
        with transaction.atomic():
            Membership.objects.create(user=request.auth, cohort=c)
    except IntegrityError:
        # 같은 사람이 두 탭에서 동시에 눌렀다 — 먼저 만든 쪽이 이겼고 결과는 같다.
        return JoinOut(cohort_id=c.id, name=c.name, created=False)
    return JoinOut(cohort_id=c.id, name=c.name, created=True)


# ---------- 학생 ----------


@student_router.get("/cohorts", response=list[MyCohortOut])
def my_cohorts(request: HttpRequest):
    memberships = Membership.objects.filter(user=request.auth).select_related("cohort").order_by(
        "cohort__archived", "-joined_at"
    )
    return [
        MyCohortOut(id=m.cohort.id, name=m.cohort.name, archived=m.cohort.archived, joined_at=m.joined_at)
        for m in memberships
    ]
