"""조직을 만들고 첫 담당자(owner)를 넣는다. 화면이 없으므로 코드에 경로가 있어야 한다.

사용자는 먼저 소셜 로그인으로 들어와 있어야 한다(사용자 이름은 `<provider>:<uid>`, 예 `kakao:12345`).
"""

from __future__ import annotations

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from orgs.models import Organization, OrgMember
from orgs.services import find_user


class Command(BaseCommand):
    help = "조직을 만들고 --owner 사용자를 owner 로 넣는다."

    def add_arguments(self, parser) -> None:
        parser.add_argument("name", help="조직 이름(유일)")
        parser.add_argument("--owner", required=True, help="owner 가 될 사용자 이름, 예 kakao:12345")

    def handle(self, *args, **options) -> None:
        name = options["name"].strip()
        if not name:
            raise CommandError("조직 이름이 비어 있습니다.")
        user = find_user(options["owner"])
        if Organization.objects.filter(name=name).exists():
            raise CommandError(f"같은 이름의 조직이 이미 있습니다: {name}")
        with transaction.atomic():
            org = Organization.objects.create(name=name)
            OrgMember.objects.create(org=org, user=user, role=OrgMember.Role.OWNER)
        self.stdout.write(f"조직 {org.name}(id {org.id}) 을 만들고 {user.username} 을 owner 로 넣었습니다.")
