"""인증 도메인 모델.

사용자는 소셜 로그인으로만 들어온다 — 비밀번호 로그인 경로는 없다(`set_unusable_password`).
사람을 이메일로 찾지 않는다: 이메일은 없을 수도, 주인이 바뀔 수도 있다. 같은 (provider,
provider_uid) 는 항상 같은 `User` 다.
"""

from __future__ import annotations

from django.conf import settings
from django.contrib.auth.models import AbstractUser
from django.db import models


class User(AbstractUser):
    #: 옛 전역 강사 플래그. 권한 판정에는 더 이상 쓰지 않는다 — 강사 권한은 조직 역할(`orgs.OrgMember`)이다.
    #: 이전(cohorts 0003)이 이 값으로 「기본 조직」 owner 를 정했다. 지울지는 다음 티켓에서 정한다.
    is_instructor = models.BooleanField(default=False)
    #: 화면에 보이는 이름. 카카오 닉네임을 로그인마다 최신값으로 받는다. 없으면 빈 문자열.
    display_name = models.CharField(max_length=100, blank=True)

    def __str__(self) -> str:  # pragma: no cover
        return self.username


class SocialAccount(models.Model):
    class Provider(models.TextChoices):
        KAKAO = "kakao", "카카오"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="social_accounts", on_delete=models.CASCADE
    )
    provider = models.CharField(max_length=16, choices=Provider.choices)
    provider_uid = models.CharField(max_length=191)
    email = models.EmailField(blank=True)
    nickname = models.CharField(max_length=100, blank=True)
    connected_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["provider", "provider_uid"], name="unique_social_identity")
        ]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.provider}:{self.provider_uid}"


class RefreshToken(models.Model):
    """회전형 리프레시 토큰의 서버측 원장. 갱신마다 옛 행에 `revoked_at` 이 찍히고 새 행이 생긴다 —
    탈취된 리프레시 토큰의 재사용은 여기서 걸린다."""

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="refresh_tokens", on_delete=models.CASCADE
    )
    jti = models.CharField(max_length=64, unique=True)
    expires_at = models.DateTimeField()
    revoked_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:  # pragma: no cover
        return self.jti
