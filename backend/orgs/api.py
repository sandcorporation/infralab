"""조직 담당자 관리·초대 API.

- 담당자 관리(/api/instructor/orgs/{org_id}/…): owner 만. 내 담당이 아닌 조직은 404, staff 는 403.
- 초대 수락(/api/org-invites/{token}): 미리보기(공개), 수락(로그인 필요).
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import instructor_auth, jwt_auth

from .models import OrgInvite, OrgMember
from .schemas import (
    InviteAcceptOut,
    InviteCreateIn,
    InviteOut,
    InvitePreviewOut,
    MemberOut,
    MemberUpdateIn,
)
from .services import owned_org

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
invite_router = Router(tags=["org-invites"])


def _member_out(m: OrgMember) -> MemberOut:
    return MemberOut(
        id=m.id,
        user_id=m.user_id,
        username=m.user.username,
        display_name=m.user.display_name,
        role=m.role,
        joined_at=m.joined_at,
    )


def _owners_locked(org_id: int):
    """마지막 owner 판정이 동시 요청에 깨지지 않게 owner 행을 잠근다."""

    return list(OrgMember.objects.select_for_update().filter(org_id=org_id, role=OrgMember.Role.OWNER))


# ---------- 담당자 ----------


@instructor_router.get("/orgs/{org_id}/members", response=list[MemberOut])
def list_members(request: HttpRequest, org_id: int):
    org = owned_org(request.auth, org_id)
    return [_member_out(m) for m in org.members.select_related("user")]


@instructor_router.patch("/orgs/{org_id}/members/{member_id}", response=MemberOut)
def update_member(request: HttpRequest, org_id: int, member_id: int, payload: MemberUpdateIn):
    org = owned_org(request.auth, org_id)
    with transaction.atomic():
        owners = _owners_locked(org.id)
        member = get_object_or_404(org.members.select_related("user"), pk=member_id)
        if member.role == OrgMember.Role.OWNER and payload.role != OrgMember.Role.OWNER and len(owners) <= 1:
            raise HttpError(409, "마지막 owner 는 staff 로 내릴 수 없습니다. 다른 owner 를 먼저 세우세요.")
        member.role = payload.role
        member.save(update_fields=["role"])
    return _member_out(member)


@instructor_router.delete("/orgs/{org_id}/members/{member_id}", response={204: None})
def remove_member(request: HttpRequest, org_id: int, member_id: int):
    org = owned_org(request.auth, org_id)
    with transaction.atomic():
        owners = _owners_locked(org.id)
        member = get_object_or_404(org.members, pk=member_id)
        if member.role == OrgMember.Role.OWNER and len(owners) <= 1:
            raise HttpError(409, "마지막 owner 는 내보낼 수 없습니다. 다른 owner 를 먼저 세우세요.")
        member.delete()
    return HttpResponse(status=204)


# ---------- 초대 링크 ----------


def _invite_out(i: OrgInvite) -> InviteOut:
    return InviteOut(id=i.id, token=i.token, role=i.role, created_at=i.created_at, expires_at=i.expires_at)


def _active_invites(org):
    return org.invites.filter(revoked_at__isnull=True, expires_at__gt=timezone.now())


@instructor_router.get("/orgs/{org_id}/invites", response=list[InviteOut])
def list_invites(request: HttpRequest, org_id: int):
    org = owned_org(request.auth, org_id)
    return [_invite_out(i) for i in _active_invites(org)]


@instructor_router.post("/orgs/{org_id}/invites", response={201: InviteOut})
def create_invite(request: HttpRequest, org_id: int, payload: InviteCreateIn):
    """같은 역할의 열린 초대 링크를 닫고 새로 만든다 — 재발급이다. 역할마다 열린 링크는 하나."""

    org = owned_org(request.auth, org_id)
    with transaction.atomic():
        _active_invites(org).filter(role=payload.role).update(revoked_at=timezone.now())
        invite = OrgInvite.objects.create(org=org, role=payload.role)
    return Status(201, _invite_out(invite))


@instructor_router.delete("/orgs/{org_id}/invites/{invite_id}", response={204: None})
def revoke_invite(request: HttpRequest, org_id: int, invite_id: int):
    org = owned_org(request.auth, org_id)
    invite = get_object_or_404(org.invites, pk=invite_id)
    if invite.revoked_at is None:
        invite.revoked_at = timezone.now()
        invite.save(update_fields=["revoked_at"])
    return HttpResponse(status=204)


# ---------- 수락 ----------


def _invite_by_token(token: str) -> OrgInvite:
    invite = OrgInvite.objects.select_related("org").filter(token=token).first()
    if invite is None:
        raise HttpError(404, "초대 링크가 올바르지 않습니다. 담당자에게 새 링크를 받으세요.")
    return invite


@invite_router.get("/org-invites/{token}", response=InvitePreviewOut, auth=None)
def preview_invite(request: HttpRequest, token: str):
    i = _invite_by_token(token)
    return InvitePreviewOut(org_name=i.org.name, role=i.role, valid=i.is_active)


@invite_router.post("/org-invites/{token}/accept", response=InviteAcceptOut, auth=jwt_auth)
def accept_invite(request: HttpRequest, token: str):
    i = _invite_by_token(token)
    if not i.is_active:
        raise HttpError(410, "만료되었거나 닫힌 초대 링크입니다. 담당자에게 새 링크를 받으세요.")
    # 이미 담당자면 역할을 건드리지 않는다 — 초대로 owner 가 staff 로 내려가는 일이 없게.
    existing = OrgMember.objects.filter(org=i.org, user=request.auth).first()
    if existing is not None:
        return InviteAcceptOut(org_id=i.org_id, org_name=i.org.name, role=existing.role, created=False)
    try:
        with transaction.atomic():
            OrgMember.objects.create(org=i.org, user=request.auth, role=i.role)
    except IntegrityError:
        return InviteAcceptOut(org_id=i.org_id, org_name=i.org.name, role=i.role, created=False)
    return InviteAcceptOut(org_id=i.org_id, org_name=i.org.name, role=i.role, created=True)
