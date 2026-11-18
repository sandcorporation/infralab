"""auth 의 `user.merged` — `from_sub` 계정을 `to_sub` 계정으로 합친다(데이터를 지우지 않고 옮긴다).

사용자를 가리키는 FK 는 기수 가입(`cohorts.Membership`)과 조직 역할(`orgs.OrgMember`) 둘이다(제출은 가입을 거쳐 간다).
새 모델이 사용자를 가리키게 되면 여기에도 옮기는 줄을 더해야 한다 — `tests/test_user_merged.py` 의 FK 목록 시험이 알려 준다.
호출하는 쪽이 트랜잭션을 연다.
"""

from __future__ import annotations

from django.contrib.auth import SESSION_KEY, get_user_model
from django.contrib.sessions.models import Session
from django.utils import timezone

from cohorts.models import Membership
from orgs.models import OrgMember
from submissions.models import Submission


#: 이 모듈이 옮긴다고 선언한 사용자 관계. 새 모델이 사용자를 가리키면 옮기는 코드를 더하고 여기에 적는다.
HANDLED = {"cohorts.Membership.user", "orgs.OrgMember.user"}


def username_for(sub: str) -> str:
    return f"sandcorp:{sub}"


def merge_users(from_sub: str, to_sub: str) -> None:
    User = get_user_model()
    if from_sub == to_sub:
        return
    source = User.objects.select_for_update().filter(username=username_for(from_sub)).first()
    if source is None:
        return
    _end_sessions(source.pk)
    target = User.objects.select_for_update().filter(username=username_for(to_sub)).first()
    if target is None:
        # 가장 단순한 경우 — 같은 사용자 행의 이름만 새 sub 로 바꾼다.
        source.username = username_for(to_sub)
        source.save(update_fields=["username"])
        return

    for membership in Membership.objects.filter(user=source):
        kept = Membership.objects.filter(user=target, cohort_id=membership.cohort_id).first()
        if kept is None:
            membership.user = target
            membership.save(update_fields=["user"])
        else:
            # 같은 기수 가입이 둘이면 제출을 한쪽으로 모으고 하나만 남긴다.
            Submission.objects.filter(membership=membership).update(membership=kept)
            membership.delete()

    for role in OrgMember.objects.filter(user=source):
        kept_role = OrgMember.objects.filter(user=target, org_id=role.org_id).first()
        if kept_role is None:
            role.user = target
            role.save(update_fields=["user"])
        else:
            if role.role == OrgMember.Role.OWNER and kept_role.role != OrgMember.Role.OWNER:
                kept_role.role = OrgMember.Role.OWNER
                kept_role.save(update_fields=["role"])
            role.delete()

    if not target.display_name and source.display_name:
        target.display_name = source.display_name
    target.is_instructor = target.is_instructor or source.is_instructor
    target.save(update_fields=["display_name", "is_instructor"])
    source.is_active = False
    source.save(update_fields=["is_active"])


def _end_sessions(user_id: int) -> None:
    """이 사용자의 로그인 세션을 지운다. 세션 키는 문자열로 저장된다."""

    for session in Session.objects.filter(expire_date__gt=timezone.now()).iterator():
        if session.get_decoded().get(SESSION_KEY) == str(user_id):
            session.delete()
