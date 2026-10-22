"""JWT 발급·검증·회전 (laurio accounts.tokens 에서 옮김 — 블랙리스트는 없다, 로그아웃 경로가 없으므로).

액세스 토큰은 짧게, 리프레시 토큰은 회전시킨다. 옛 리프레시는 `RefreshToken.revoked_at`
이 찍혀 재사용이 막힌다 — 회수는 UPDATE 한 번으로 판정까지 끝내 같은 토큰의 동시 재사용
중 하나만 이긴다.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

import jwt
from django.conf import settings
from django.contrib.auth import get_user_model
from django.utils import timezone

from .models import RefreshToken

ALGORITHM = "HS256"


class TokenError(Exception):
    """토큰이 서명·만료·타입·회수 검증 중 하나라도 실패했을 때."""


@dataclass(frozen=True)
class TokenPair:
    access: str
    refresh: str


def _encode(*, user_id: int, token_type: str, ttl: timedelta) -> tuple[str, str, datetime]:
    jti = uuid.uuid4().hex
    now = timezone.now()
    exp = now + ttl
    payload = {
        "sub": str(user_id),
        "jti": jti,
        "type": token_type,
        "iat": int(now.timestamp()),
        "exp": int(exp.timestamp()),
    }
    return jwt.encode(payload, settings.JWT_SIGNING_KEY, algorithm=ALGORITHM), jti, exp


def issue_token_pair(user_id: int) -> TokenPair:
    access, _, _ = _encode(user_id=user_id, token_type="access", ttl=settings.ACCESS_TOKEN_TTL)
    refresh, refresh_jti, refresh_exp = _encode(
        user_id=user_id, token_type="refresh", ttl=settings.REFRESH_TOKEN_TTL
    )
    RefreshToken.objects.create(user_id=user_id, jti=refresh_jti, expires_at=refresh_exp)
    # 원장이 무한히 자라지 않게 — 이 사용자의 만료 지난 행은 더 쓸 일이 없다.
    RefreshToken.objects.filter(user_id=user_id, expires_at__lt=timezone.now()).delete()
    return TokenPair(access=access, refresh=refresh)


def decode_token(token: str, *, expected_type: str) -> dict:
    """서명·만료·타입을 검증한다. 실패하면 항상 `TokenError`. 리프레시의 회수 여부는
    `rotate_refresh_token` 이 회수와 한 번에 판정한다."""

    try:
        payload = jwt.decode(token, settings.JWT_SIGNING_KEY, algorithms=[ALGORITHM])
    except jwt.PyJWTError as exc:
        raise TokenError("invalid or expired token") from exc
    if payload.get("type") != expected_type:
        raise TokenError(f"expected a {expected_type} token")
    if not payload.get("jti"):
        raise TokenError("token has no jti")
    return payload


def rotate_refresh_token(refresh_token: str) -> TokenPair:
    """리프레시 토큰 하나를 소모하고 새 access/refresh 쌍을 돌려준다."""

    payload = decode_token(refresh_token, expected_type="refresh")
    user_id = int(payload["sub"])
    revoked = RefreshToken.objects.filter(
        jti=payload["jti"], user_id=user_id, revoked_at__isnull=True
    ).update(revoked_at=timezone.now())
    if revoked == 0:
        raise TokenError("refresh token has been revoked")
    if not get_user_model().objects.filter(pk=user_id, is_active=True).exists():
        raise TokenError("account is inactive")
    return issue_token_pair(user_id)
