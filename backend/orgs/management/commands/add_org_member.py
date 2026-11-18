"""조직에 담당자를 넣는다. 이미 담당자면 역할만 바꾼다.

`<org>` 는 조직 id 또는 이름. 역할은 기본 owner, `--role staff` 로 staff.
"""

from __future__ import annotations

from django.core.management.base import BaseCommand

from orgs.models import OrgMember
from orgs.services import find_org, find_user


class Command(BaseCommand):
    help = "조직에 담당자를 넣는다(이미 있으면 역할을 바꾼다)."

    def add_arguments(self, parser) -> None:
        parser.add_argument("org", help="조직 id 또는 이름")
        parser.add_argument("username", help="사용자 이름, 예 kakao:12345")
        parser.add_argument("--role", choices=[r.value for r in OrgMember.Role], default=OrgMember.Role.OWNER)

    def handle(self, *args, **options) -> None:
        org = find_org(options["org"])
        user = find_user(options["username"])
        member, created = OrgMember.objects.update_or_create(
            org=org, user=user, defaults={"role": options["role"]}
        )
        verb = "넣었습니다" if created else "역할을 바꿨습니다"
        self.stdout.write(f"{user.username} 을 조직 {org.name} 에 {member.role} 로 {verb}.")
