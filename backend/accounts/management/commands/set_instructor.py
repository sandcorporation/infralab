"""옛 강사 부트스트랩 명령 — 이제 「기본 조직」의 담당자로 넣고 빼는 지름길이다.

강사 권한은 조직 역할로 옮겨 갔다(docs/adr/0002-organization-structure.md). 이 명령은 사용자를
「기본 조직」(없으면 만든다)의 owner 로 넣고, `--off` 면 그 조직에서 뺀다. 다른 조직의 담당 자격은
건드리지 않는다. 옛 `is_instructor` 플래그도 같이 맞춰 두지만 권한 판정에는 쓰이지 않는다.
새 조직은 `create_org`, 담당자 추가는 `add_org_member`.

사용자는 먼저 로그인으로 들어와 있어야 한다(사용자 이름은 auth `sub` 로 만든
`sandcorp:<sub>`).
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from orgs.models import DEFAULT_ORG_NAME, Organization, OrgMember


class Command(BaseCommand):
    help = f"사용자를 「{DEFAULT_ORG_NAME}」의 owner 로 넣는다(--off 면 뺀다)."

    def add_arguments(self, parser) -> None:
        parser.add_argument("username", help="로그인으로 만들어진 사용자 이름, 예 sandcorp:m_01JB…")
        parser.add_argument("--off", action="store_true", help=f"「{DEFAULT_ORG_NAME}」에서 뺀다")

    def handle(self, *args, **options) -> None:
        User = get_user_model()
        user = User.objects.filter(username=options["username"]).first()
        if user is None:
            raise CommandError(
                f"사용자가 없습니다: {options['username']} — 먼저 로그인으로 들어와야 합니다."
            )
        with transaction.atomic():
            if options["off"]:
                OrgMember.objects.filter(org__name=DEFAULT_ORG_NAME, user=user).delete()
            else:
                org, _ = Organization.objects.get_or_create(name=DEFAULT_ORG_NAME)
                OrgMember.objects.update_or_create(org=org, user=user, defaults={"role": OrgMember.Role.OWNER})
            user.is_instructor = not options["off"]
            user.save(update_fields=["is_instructor"])
        state = "에서 뺐습니다" if options["off"] else "의 owner 로 넣었습니다"
        self.stdout.write(f"{user.username} 을 「{DEFAULT_ORG_NAME}」{state}.")
