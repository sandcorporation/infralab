"""소셜 로그인 제공자 어댑터 (laurio accounts.social 에서 옮김 — 카카오 + Fake 만).

프런트엔드가 카카오 OAuth 를 마치고 얻은 access token 을 백엔드로 넘기면, 어댑터가 그
토큰으로 제공자에게 프로필을 조회해 신뢰할 수 있는 provider_uid 를 확정한다. dev/test 는
Fake 로 바인딩돼 네트워크 없이 결정적으로 동작한다.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Protocol

#: User.username(150자) 에 `<provider>:` 접두를 붙여도 들어가는 길이.
MAX_PROVIDER_UID = 140
MAX_NICKNAME = 100


class SocialLoginError(Exception):
    """제공자가 토큰을 거부했거나 프로필을 내려주지 않았을 때."""


@dataclass(frozen=True)
class SocialProfile:
    provider: str
    provider_uid: str
    email: str = ""
    nickname: str = ""


class SocialAdapter(Protocol):
    def fetch_profile(self, access_token: str) -> SocialProfile: ...


def _profile(provider: str, uid: str, email: str, nickname: str) -> SocialProfile:
    if not uid:
        raise SocialLoginError(f"{provider} profile missing id")
    if len(uid) > MAX_PROVIDER_UID:
        raise SocialLoginError(f"{provider} profile id too long")
    return SocialProfile(provider=provider, provider_uid=uid, email=email[:254], nickname=nickname[:MAX_NICKNAME])


def _get_json(url: str, access_token: str) -> dict:
    request = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310
            data = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        # TimeoutError 는 OSError 의 하위다 — 본문 읽기 중 타임아웃도 여기로 온다.
        raise SocialLoginError(f"provider profile fetch failed: {exc}") from exc
    if not isinstance(data, dict):
        raise SocialLoginError("provider profile is not an object")
    return data


class KakaoAdapter:
    """카카오 사용자 정보 조회. https://kapi.kakao.com/v2/user/me"""

    def fetch_profile(self, access_token: str) -> SocialProfile:
        data = _get_json("https://kapi.kakao.com/v2/user/me", access_token)
        uid = data.get("id")
        kakao_account = data.get("kakao_account") or {}
        profile = kakao_account.get("profile") or {}
        properties = data.get("properties") or {}
        return _profile(
            "kakao",
            "" if uid is None else str(uid),
            kakao_account.get("email") or "",
            profile.get("nickname") or properties.get("nickname") or "",
        )


class FakeSocialAdapter:
    """dev/test 전용. 네트워크 없이 access_token 문자열을 그대로 파싱한다.

    형식: ``"<provider_uid>:<email>"`` 또는 ``"<provider_uid>:<email>:<nickname>"``.
    """

    def __init__(self, provider: str) -> None:
        self._provider = provider

    def fetch_profile(self, access_token: str) -> SocialProfile:
        if not access_token or ":" not in access_token:
            raise SocialLoginError("fake token must be '<uid>:<email>[:<nickname>]'")
        uid, email, *rest = access_token.split(":", 2)
        return _profile(self._provider, uid, email, rest[0] if rest else "")


_REAL_ADAPTERS: dict[str, SocialAdapter] = {
    "kakao": KakaoAdapter(),
}


def get_adapter(provider: str) -> SocialAdapter:
    from django.conf import settings

    if provider not in _REAL_ADAPTERS:
        raise SocialLoginError(f"unsupported provider: {provider}")
    if settings.SOCIAL_AUTH_MODE == "fake":
        return FakeSocialAdapter(provider)
    return _REAL_ADAPTERS[provider]
