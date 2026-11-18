"""조직 권한 판정 — 강사 표면이 모두 이 함수들로 「내 조직의 것인가」를 본다.

남의 조직의 묶음·제출은 존재 여부도 알리지 않는다(404).
"""

from __future__ import annotations

from django.contrib.auth.models import AbstractBaseUser
from django.core.management.base import CommandError
from django.db.models import QuerySet
from django.shortcuts import get_object_or_404
from ninja.errors import HttpError

from .models import Organization, OrgMember


def is_org_staff(user: AbstractBaseUser) -> bool:
    """담당 조직이 하나라도 있는가 — 강사 표면의 입장권이자 `/accounts/me` 의 `is_instructor`."""

    return OrgMember.objects.filter(user=user).exists()


def my_org_ids(user: AbstractBaseUser) -> QuerySet:
    return OrgMember.objects.filter(user=user).values("org_id")


def my_orgs(user: AbstractBaseUser) -> list[OrgMember]:
    return list(OrgMember.objects.filter(user=user).select_related("org").order_by("org__created_at", "org_id"))


def find_org(ref: str) -> Organization:
    """관리 명령의 `<org>` — 숫자면 id, 아니면 이름."""

    org = Organization.objects.filter(pk=int(ref)).first() if ref.isdigit() else None
    if org is None:
        org = Organization.objects.filter(name=ref).first()
    if org is None:
        raise CommandError(f"조직이 없습니다: {ref}")
    return org


def find_user(username: str):
    from django.contrib.auth import get_user_model

    user = get_user_model().objects.filter(username=username).first()
    if user is None:
        raise CommandError(f"사용자가 없습니다: {username} — 먼저 소셜 로그인으로 들어와야 합니다.")
    return user


def owned_org(user: AbstractBaseUser, org_id: int) -> Organization:
    """담당자 관리의 대상 조직. 내 담당이 아니면 404(존재도 알리지 않는다), staff 면 403 — owner 만 관리한다."""

    member = get_object_or_404(OrgMember.objects.select_related("org"), user=user, org_id=org_id)
    if member.role != OrgMember.Role.OWNER:
        raise HttpError(403, "owner 만 담당자를 관리할 수 있습니다.")
    return member.org
