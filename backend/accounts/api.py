"""인증·계정 API."""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.http import HttpRequest
from ninja import Router
from ninja.errors import HttpError

from .auth import instructor_auth, jwt_auth
from .models import SocialAccount
from .schemas import MeOut, RefreshIn, SocialLoginIn, TokenPairOut
from .social import SocialLoginError, SocialProfile, get_adapter
from .tokens import TokenError, issue_token_pair, rotate_refresh_token

router = Router(tags=["auth"])
instructor_router = Router(tags=["instructor"], auth=instructor_auth)


def _username_for(profile: SocialProfile) -> str:
    return f"{profile.provider}:{profile.provider_uid}"


def _create_user(profile: SocialProfile):
    User = get_user_model()
    # 사용자 행이 소셜 계정 행 없이 남아 있을 수 있다(복구 중 지워진 경우) — 그때도 로그인은 돼야 한다.
    user, created = User.objects.get_or_create(
        username=_username_for(profile), defaults={"display_name": profile.nickname}
    )
    if created:
        user.set_unusable_password()
        user.save(update_fields=["password"])
    SocialAccount.objects.create(
        user=user,
        provider=profile.provider,
        provider_uid=profile.provider_uid,
        email=profile.email,
        nickname=profile.nickname,
    )
    return user


@router.post("/auth/social/{provider}/login", response=TokenPairOut, auth=None)
def social_login(request: HttpRequest, provider: str, payload: SocialLoginIn):
    """소셜 access token 으로 로그인한다(최초 로그인 시 가입까지 겸한다). 비밀번호는 어디에도 없다."""

    try:
        profile = get_adapter(provider).fetch_profile(payload.access_token)
    except SocialLoginError as exc:
        raise HttpError(401, f"소셜 로그인에 실패했습니다: {exc}") from exc

    account = SocialAccount.objects.select_related("user").filter(
        provider=profile.provider, provider_uid=profile.provider_uid
    ).first()
    if account is None:
        try:
            # 같은 사람의 첫 로그인 둘이 동시에 들어오면(버튼 두 번) 늦은 쪽이 유일 제약에 걸린다 —
            # 이 savepoint 만 되돌리고 먼저 만든 쪽의 계정으로 간다.
            with transaction.atomic():
                user = _create_user(profile)
        except IntegrityError:
            account = SocialAccount.objects.select_related("user").get(
                provider=profile.provider, provider_uid=profile.provider_uid
            )
    if account is not None:
        user = account.user
        if not user.is_active:
            raise HttpError(403, "비활성화된 계정입니다.")
        # 닉네임·이메일은 로그인마다 최신값으로.
        account.email = profile.email
        account.nickname = profile.nickname
        account.save(update_fields=["email", "nickname"])
        if profile.nickname and user.display_name != profile.nickname:
            user.display_name = profile.nickname
            user.save(update_fields=["display_name"])

    pair = issue_token_pair(user.id)
    return TokenPairOut(access=pair.access, refresh=pair.refresh)


@router.post("/auth/refresh", response=TokenPairOut, auth=None)
def refresh(request: HttpRequest, payload: RefreshIn):
    try:
        pair = rotate_refresh_token(payload.refresh)
    except TokenError as exc:
        raise HttpError(401, str(exc)) from exc
    return TokenPairOut(access=pair.access, refresh=pair.refresh)


def _me(user) -> MeOut:
    return MeOut(
        id=user.id, username=user.username, display_name=user.display_name, is_instructor=user.is_instructor
    )


@router.get("/accounts/me", response=MeOut, auth=jwt_auth)
def me(request: HttpRequest):
    return _me(request.auth)


@instructor_router.get("/me", response=MeOut)
def instructor_me(request: HttpRequest):
    """강사 표면의 입구 — 화면이 강사 메뉴를 열기 전에 친다."""

    return _me(request.auth)
