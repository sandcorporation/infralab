"""기수·가입 API.

- 강사(/api/instructor/cohorts…): 기수 만들기·목록·이름 변경·참여자 목록 — 내가 담당자인 조직의 기수만
- 가입(/api/join/{token}): 미리보기(공개), 참여(로그인 필요)
- 학생(/api/cohorts): 내 기수 목록
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.db.models import Count
from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import instructor_auth, jwt_auth

from .compose import AGENT_PORT, render_compose
from .models import Cohort, Membership, new_token
from orgs.services import my_orgs

from .services import managed_cohort, managed_cohorts, my_membership, open_scenario_ids
from .schemas import (
    CohortCreateIn,
    CohortOut,
    CohortUpdateIn,
    JoinOut,
    JoinPreviewOut,
    MyCohortDetailOut,
    MyCohortOut,
    ParticipantOut,
)

AGENT_URL = f"http://127.0.0.1:{AGENT_PORT}"

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
join_router = Router(tags=["join"])
student_router = Router(tags=["student"], auth=jwt_auth)


def _cohorts_with_counts(user):
    """강사 표면이 쓰는 질의 — 내 조직의 기수만, 참여자 수를 함께 센다. GROUP BY 가 있어 Meta.ordering 이
    적용되지 않으므로 명시한다."""

    return managed_cohorts(user).annotate(member_count=Count("memberships")).order_by("archived", "-created_at")


def _cohort_out(c: Cohort) -> CohortOut:
    return CohortOut(
        id=c.id,
        org_id=c.org_id,
        name=c.name,
        kind=c.kind,
        exam_settings=c.exam_settings,
        join_token=c.join_token,
        join_open=c.join_open,
        archived=c.archived,
        open_scenario_ids=open_scenario_ids(c),
        member_count=getattr(c, "member_count", 0),
        created_at=c.created_at,
    )


# ---------- 강사 ----------


@instructor_router.post("/cohorts", response={201: CohortOut})
def create_cohort(request: HttpRequest, payload: CohortCreateIn):
    orgs = my_orgs(request.auth)
    if payload.org_id is None:
        if len(orgs) != 1:
            raise HttpError(422, "담당 조직이 여럿입니다. 기수를 둘 조직(org_id)을 고르세요.")
        org_id = orgs[0].org_id
    else:
        if payload.org_id not in {m.org_id for m in orgs}:
            raise HttpError(403, "그 조직의 담당자가 아닙니다.")
        org_id = payload.org_id
    cohort = Cohort.objects.create(org_id=org_id, name=payload.name, kind=payload.kind)
    return Status(201, _cohort_out(cohort))


@instructor_router.get("/cohorts", response=list[CohortOut])
def list_cohorts(request: HttpRequest):
    return [_cohort_out(c) for c in _cohorts_with_counts(request.auth)]


@instructor_router.get("/cohorts/{cohort_id}", response=CohortOut)
def get_cohort(request: HttpRequest, cohort_id: int):
    return _cohort_out(get_object_or_404(_cohorts_with_counts(request.auth), pk=cohort_id))


@instructor_router.patch("/cohorts/{cohort_id}", response=CohortOut)
def update_cohort(request: HttpRequest, cohort_id: int, payload: CohortUpdateIn):
    cohort = get_object_or_404(_cohorts_with_counts(request.auth), pk=cohort_id)
    # 보낸 필드만 바꾼다 — 스키마 검증기가 이름을 이미 다듬었다.
    changes = payload.dict(exclude_unset=True, exclude_none=True)
    for field, value in changes.items():
        setattr(cohort, field, value)
    if changes:
        cohort.save(update_fields=list(changes))
    return _cohort_out(cohort)


@instructor_router.post("/cohorts/{cohort_id}/join-token/regenerate", response=CohortOut)
def regenerate_join_token(request: HttpRequest, cohort_id: int):
    """옛 링크를 즉시 무효화한다 — 링크가 새어 나갔을 때."""

    cohort = get_object_or_404(_cohorts_with_counts(request.auth), pk=cohort_id)
    cohort.join_token = new_token()
    cohort.save(update_fields=["join_token"])
    return _cohort_out(cohort)


@instructor_router.delete("/cohorts/{cohort_id}/participants/{membership_id}", response={204: None})
def remove_participant(request: HttpRequest, cohort_id: int, membership_id: int):
    cohort = managed_cohort(request, cohort_id)
    deleted, _ = Membership.objects.filter(pk=membership_id, cohort=cohort).delete()
    if not deleted:
        raise HttpError(404, "그 학생은 이 기수에 없습니다.")
    # 204 는 본문이 없어야 한다 — JSON null 을 붙이지 않는다.
    return HttpResponse(status=204)


@instructor_router.get("/cohorts/{cohort_id}/participants", response=list[ParticipantOut])
def list_participants(request: HttpRequest, cohort_id: int):
    cohort = managed_cohort(request, cohort_id)
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


def _my_cohort_detail(m: Membership) -> MyCohortDetailOut:
    return MyCohortDetailOut(
        id=m.cohort.id,
        name=m.cohort.name,
        archived=m.cohort.archived,
        joined_at=m.joined_at,
        agent_token=m.agent_token,
        agent_url=AGENT_URL,
    )


@student_router.get("/cohorts/{cohort_id}", response=MyCohortDetailOut)
def my_cohort(request: HttpRequest, cohort_id: int):
    return _my_cohort_detail(my_membership(request, cohort_id))


@student_router.get("/cohorts/{cohort_id}/compose.yml")
def my_compose_file(request: HttpRequest, cohort_id: int):
    """내 에이전트 토큰이 박힌 compose.yml. 설치가 파일 하나와 명령 하나가 되게."""

    m = my_membership(request, cohort_id)
    body = render_compose(agent_token=m.agent_token, cohort_name=m.cohort.name)
    response = HttpResponse(body, content_type="text/yaml; charset=utf-8")
    response["Content-Disposition"] = 'attachment; filename="compose.yml"'
    return response


@student_router.post("/cohorts/{cohort_id}/agent-token/regenerate", response=MyCohortDetailOut)
def regenerate_agent_token(request: HttpRequest, cohort_id: int):
    """노트북을 바꿨거나 토큰이 새었을 때. 옛 compose.yml 의 에이전트는 더 이상 인증되지 않는다."""

    m = my_membership(request, cohort_id)
    for attempt in range(3):
        m.agent_token = new_token()
        try:
            with transaction.atomic():
                m.save(update_fields=["agent_token"])
            break
        except IntegrityError:
            # 유일 제약 충돌은 천문학적으로 드물지만 500 대신 다시 뽑는다.
            if attempt == 2:
                raise
    return _my_cohort_detail(m)
