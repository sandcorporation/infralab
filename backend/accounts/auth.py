"""django-ninja 인증 클래스 — Django 세션 쿠키.

로그인은 sandcorp-auth 콜백(또는 개발용 dev-login)이 Django 세션을 만든다(`accounts.api`). API 는 그 세션
쿠키로 사용자를 `request.auth` 에 둔다. 세션이 없거나 사용자가 비활성이면 401.

CSRF: 쿠키로 들어온 GET·HEAD·OPTIONS 밖 요청은 `Origin` 이 대시보드 오리진(`DASHBOARD_ORIGIN` 중 하나)이어야
한다 — 아니면 403. 세션 쿠키는 SameSite=Lax 지만 같은 사이트의 다른 하위 도메인까지 막지는 않는다.

강사 전용 표면은 `InstructorAuth` 가 「담당 조직이 하나라도 있는가」까지 본다 — 로그인은 됐지만 어느
조직의 담당자도 아니면 403 이다(401 과 구분해 화면이 「권한 없음」을 말할 수 있게). 어떤 기수·제출이
내 조직의 것인지는 각 엔드포인트가 `cohorts.services.managed_cohorts` 로 본다.

`jwt_auth` 라는 이름은 옛 JWT 시절의 것이다 — 다른 앱의 라우터가 이 이름으로 가져다 쓴다.
"""

from __future__ import annotations

from django.conf import settings
from django.contrib.auth import get_user
from django.http import HttpRequest
from ninja.errors import HttpError
from ninja.security import APIKeyCookie

from orgs.services import is_org_staff

SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})


def check_origin(request: HttpRequest) -> None:
    """쿠키로 상태를 바꾸는 요청의 `Origin` 이 대시보드 오리진이 아니면 403."""

    if request.method in SAFE_METHODS:
        return
    if request.headers.get("Origin") not in settings.DASHBOARD_ORIGINS:
        raise HttpError(403, "허용되지 않은 출처의 요청입니다.")


class SessionAuth(APIKeyCookie):
    def __init__(self) -> None:
        super().__init__(csrf=False)
        self.param_name = settings.SESSION_COOKIE_NAME

    def authenticate(self, request: HttpRequest, key: str | None):
        user = get_user(request)
        if not user.is_authenticated:
            return None
        check_origin(request)
        return user


class InstructorAuth(SessionAuth):
    def authenticate(self, request: HttpRequest, key: str | None):
        user = super().authenticate(request, key)
        if user is None:
            return None
        if not is_org_staff(user):
            raise HttpError(403, "강사만 쓸 수 있습니다.")
        return user


jwt_auth = SessionAuth()
instructor_auth = InstructorAuth()
