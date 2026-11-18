"""인증·계정 API — sandcorp-auth 로그인(기밀 클라이언트·PKCE), 세션, 로그아웃, 탈퇴·합치기 웹훅, 개발용 로그인."""

from __future__ import annotations

import hmac
import logging
import time
from datetime import timedelta

from django.conf import settings
from django.contrib.auth import get_user_model, login, logout
from django.db import IntegrityError, transaction
from django.http import HttpRequest, HttpResponse, HttpResponseRedirect, JsonResponse
from django.utils import timezone
from ninja import Router, Schema, Status
from ninja.errors import HttpError

from orgs.services import my_orgs

from . import sandcorp_auth
from .auth import check_origin, instructor_auth, jwt_auth
from .merge import merge_users
from .models import WebhookEvent
from .schemas import MeOut, OrgOut

log = logging.getLogger(__name__)

router = Router(tags=["auth"])
instructor_router = Router(tags=["instructor"], auth=instructor_auth)

#: 세션에 둔 로그인 시도의 키와 수명.
ATTEMPT_KEY = "infralab.login_attempt"
ATTEMPT_TTL_SECONDS = 600
#: 처리한 웹훅 id 를 기억하는 기간(W4: 3일 이상).
WEBHOOK_MEMORY = timedelta(days=7)
#: Django 인증 백엔드 — `login()` 이 세션에 적는다.
BACKEND = "django.contrib.auth.backends.ModelBackend"


def _username(sub: str) -> str:
    return f"sandcorp:{sub}"


def _login_user(request: HttpRequest, sub: str, display_name: str):
    """`sub` 의 사용자를 찾거나 만들고 Django 세션을 연다. 비활성 사용자면 None."""

    User = get_user_model()
    try:
        # 같은 사람의 첫 로그인 둘이 동시에 들어오면 늦은 쪽이 유일 제약에 걸린다 — 먼저 만든 쪽으로 간다.
        with transaction.atomic():
            user, created = User.objects.get_or_create(username=_username(sub), defaults={"display_name": display_name})
    except IntegrityError:
        user, created = User.objects.get(username=_username(sub)), False
    if created:
        user.set_unusable_password()
        user.save(update_fields=["password"])
    if not user.is_active:
        return None
    if display_name and user.display_name != display_name:
        user.display_name = display_name
        user.save(update_fields=["display_name"])
    login(request, user, backend=BACKEND)
    return user


def _dashboard(path: str) -> HttpResponseRedirect:
    return HttpResponseRedirect(f"{settings.PUBLIC_ORIGIN}{path}")


def _not_configured() -> JsonResponse:
    return JsonResponse({"detail": "로그인이 아직 설정되지 않았습니다."}, status=503)


@router.get("/auth/login", auth=None, include_in_schema=False)
def auth_login(request: HttpRequest, next: str = "/"):  # noqa: A002 — 쿼리 이름이 next 다
    """auth 의 /authorize 로 보낸다. state·verifier·next 는 서버 쪽 세션에만 둔다."""

    if not sandcorp_auth.client_configured():
        return _not_configured()
    attempt = sandcorp_auth.new_attempt(next)
    request.session[ATTEMPT_KEY] = dict(attempt)
    return HttpResponseRedirect(sandcorp_auth.authorize_url(attempt))


@router.get("/auth/callback", auth=None, include_in_schema=False)
def auth_callback(request: HttpRequest):
    if not sandcorp_auth.client_configured():
        return _not_configured()
    # 시도는 결과와 상관없이 한 번 쓰고 지운다(재사용 금지).
    attempt = request.session.pop(ATTEMPT_KEY, None)
    failed = _dashboard("/login?error=1")
    if not isinstance(attempt, dict):
        return failed
    if request.GET.get("error"):
        log.info("auth login refused: %s", request.GET.get("error"))
        return failed
    if time.time() - float(attempt.get("created_at", 0)) > ATTEMPT_TTL_SECONDS:
        return failed
    state = request.GET.get("state", "")
    code = request.GET.get("code", "")
    if not state or not code or not hmac.compare_digest(state.encode(), str(attempt.get("state", "")).encode()):
        return failed
    try:
        tokens = sandcorp_auth.exchange_code(code, str(attempt["verifier"]))
        sub = sandcorp_auth.verify_access_token(tokens.access_token)
    except sandcorp_auth.AuthFlowError as exc:
        log.warning("auth login failed: %s", exc)
        return failed
    name = sandcorp_auth.display_name_from_id_token(tokens.id_token, sub)
    if _login_user(request, sub, name) is None:
        return failed
    return _dashboard(sandcorp_auth.safe_next(str(attempt.get("next", "/"))))


@router.post("/auth/logout", auth=None, response={204: None})
def auth_logout(request: HttpRequest):
    """이 사이트의 세션만 끊는다(auth 에는 end-session 이 없다)."""

    check_origin(request)
    logout(request)
    return Status(204, None)


class DevLoginIn(Schema):
    uid: str
    nickname: str = ""


@router.post("/auth/dev-login", auth=None, response={204: None})
def dev_login(request: HttpRequest, payload: DevLoginIn):
    """개발·시험 전용 — auth 없이 `sandcorp:<uid>` 로 세션을 연다. DEBUG 가 아니면 없는 주소다."""

    if not settings.DEV_LOGIN_ENABLED:
        raise HttpError(404, "Not Found")
    uid = payload.uid.strip()
    if not uid or len(uid) > sandcorp_auth.MAX_SUB:
        raise HttpError(422, "uid 는 1~140자입니다.")
    if _login_user(request, uid, payload.nickname.strip()[: sandcorp_auth.MAX_NAME]) is None:
        raise HttpError(403, "비활성화된 계정입니다.")
    return Status(204, None)


@router.post("/auth/webhook", auth=None, include_in_schema=False)
def auth_webhook(request: HttpRequest):
    """auth 의 웹훅(W1~W5) — 탈퇴 `user.deleted`, 계정 합치기 `user.merged`. 본문은 받은 바이트 그대로 검증한다."""

    secret = settings.INFRALAB_AUTH_WEBHOOK_SECRET
    if not secret:
        return _not_configured()
    try:
        event = sandcorp_auth.verify_webhook(secret, request.body, request.headers.get("X-Sandcorp-Signature", ""))
    except sandcorp_auth.WebhookRejected as exc:
        return JsonResponse({"detail": str(exc)}, status=exc.status)
    event_id = str(event["id"])[:64]
    with transaction.atomic():
        _, fresh = WebhookEvent.objects.get_or_create(id=event_id)
        if fresh and event["type"] == "user.deleted" and isinstance(event.get("sub"), str):
            _forget(str(event["sub"]))
        elif fresh and event["type"] == "user.merged":
            from_sub, to_sub = event.get("from_sub"), event.get("to_sub")
            if isinstance(from_sub, str) and isinstance(to_sub, str) and from_sub and to_sub:
                merge_users(from_sub, to_sub)
    WebhookEvent.objects.filter(received_at__lt=timezone.now() - WEBHOOK_MEMORY).delete()
    return HttpResponse(status=204)


def _forget(sub: str) -> None:
    """탈퇴한 `sub` — 비활성으로 돌리고 표시 이름을 지운다. 세션 인증이 비활성 사용자를 거르므로 열린 세션도 끝난다.

    기수 참가·제출 기록은 강사의 성적 자료라 행은 남긴다(사용자 이름은 `sandcorp:<sub>` 뿐이다)."""

    get_user_model().objects.filter(username=_username(sub)).update(is_active=False, display_name="")


def _me(user) -> MeOut:
    orgs = [OrgOut(id=m.org.id, name=m.org.name, role=m.role) for m in my_orgs(user)]
    return MeOut(
        id=user.id,
        username=user.username,
        display_name=user.display_name,
        is_instructor=bool(orgs),
        orgs=orgs,
    )


@router.get("/accounts/me", response=MeOut, auth=jwt_auth)
def me(request: HttpRequest):
    return _me(request.auth)


@instructor_router.get("/me", response=MeOut)
def instructor_me(request: HttpRequest):
    """강사 표면의 입구 — 화면이 강사 메뉴를 열기 전에 친다."""

    return _me(request.auth)
