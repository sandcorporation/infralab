"""django-ninja 인증 클래스.

`Authorization: Bearer <access token>` 을 읽어 사용자를 `request.auth` 에 둔다. 토큰이 없거나
무효면 401. 강사 전용 표면은 `InstructorAuth` 가 「담당 조직이 하나라도 있는가」까지 본다 — 로그인은
됐지만 어느 조직의 담당자도 아니면 403 이다(401 과 구분해 화면이 「권한 없음」을 말할 수 있게). 어떤
기수·제출이 내 조직의 것인지는 각 엔드포인트가 `cohorts.services.managed_cohorts` 로 본다.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from ninja.errors import HttpError
from ninja.security import HttpBearer

from orgs.services import is_org_staff

from .tokens import TokenError, decode_token


class JWTAuth(HttpBearer):
    def authenticate(self, request, token):
        try:
            payload = decode_token(token, expected_type="access")
        except TokenError:
            return None
        User = get_user_model()
        return User.objects.filter(pk=int(payload["sub"]), is_active=True).first()


class InstructorAuth(JWTAuth):
    def authenticate(self, request, token):
        user = super().authenticate(request, token)
        if user is None:
            return None
        if not is_org_staff(user):
            raise HttpError(403, "강사만 쓸 수 있습니다.")
        return user


jwt_auth = JWTAuth()
instructor_auth = InstructorAuth()
