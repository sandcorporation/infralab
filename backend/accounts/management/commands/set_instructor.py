"""첫 강사를 지정하는 부트스트랩 명령. 화면이 없으므로 코드에 경로가 있어야 한다.

사용자는 먼저 소셜 로그인으로 들어와 있어야 한다(사용자 이름은 `<provider>:<uid>`, 예
`kakao:12345`). `--off` 로 내릴 수 있다.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "사용자의 강사 플래그를 켠다(--off 면 내린다)."

    def add_arguments(self, parser) -> None:
        parser.add_argument("username", help="소셜 로그인으로 만들어진 사용자 이름, 예 kakao:12345")
        parser.add_argument("--off", action="store_true", help="강사 플래그를 내린다")

    def handle(self, *args, **options) -> None:
        User = get_user_model()
        user = User.objects.filter(username=options["username"]).first()
        if user is None:
            raise CommandError(
                f"사용자가 없습니다: {options['username']} — 먼저 소셜 로그인으로 들어와야 합니다."
            )
        user.is_instructor = not options["off"]
        user.save(update_fields=["is_instructor"])
        state = "내렸습니다" if options["off"] else "켰습니다"
        self.stdout.write(f"{user.username} 의 강사 플래그를 {state}.")
