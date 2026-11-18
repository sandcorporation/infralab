"""sandcorp-auth(OIDC/OAuth 서버) 기밀 클라이언트 — 인가 요청 만들기, 코드 교환, 토큰 검증, 웹훅 서명 검증.

규칙의 원문은 auth 저장소 `docs/resource-server-token-validation.md`(3절 T·S, 4절 JWKS 캐시, 10절 A·ID 토큰,
11절 W). 여기서는 그 요약대로 짠다:

- 액세스 토큰: EdDSA 서명(JWKS `kid`), `iss`=AUTH_URL, `aud`={공개 원점}/api(문자열 완전 일치), `exp`+30초,
  `scope` 에 `infralab`. `acct` 가 없으면 대표 토큰, `"member"` 면 `sub` 가 `m_`+ULID, 그 밖(기계 토큰 등)은 거부.
- ID 토큰: 같은 JWKS, `iss`, `aud`=client_id. `sub` 가 액세스 토큰과 같을 때만 `name` 을 표시 이름으로 쓴다.
- 웹훅: `X-Sandcorp-Signature: t=…,v1=…`, 받은 본문 바이트로 HMAC-SHA256, 300초 창.

바깥 HTTP 는 `_http` 하나로만 나간다 — 시험은 이것을 가짜 auth 서버로 바꾼다.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import TypedDict

import jwt
from django.conf import settings

#: JSON 값. 토큰 클레임·응답 본문처럼 모양을 아직 모르는 값 — 쓰기 전에 좁힌다.
JSON = dict[str, "JSON"] | list["JSON"] | str | int | float | bool | None

REQUIRED_SCOPE = "infralab"
EXP_LEEWAY_SECONDS = 30
JWKS_TTL_SECONDS = 600
JWKS_REFETCH_MIN_SECONDS = 60
HTTP_TIMEOUT_SECONDS = 5
WEBHOOK_TOLERANCE_SECONDS = 300
MEMBER_SUB = re.compile(r"^m_[0-7][0-9A-HJKMNP-TV-Z]{25}$")
#: User.username(150자)에 `sandcorp:` 접두를 붙여도 들어가는 길이.
MAX_SUB = 140
MAX_NAME = 100


class AuthFlowError(Exception):
    """인가 흐름·토큰 검증 중 하나라도 실패했을 때. 메시지는 로그용이다(화면에는 내보내지 않는다)."""


@dataclass(frozen=True)
class HttpResponse:
    status: int
    body: bytes


def _http(method: str, url: str, headers: dict[str, str], body: bytes | None = None) -> HttpResponse:
    """바깥으로 나가는 HTTP 한 번. 4xx·5xx 도 응답으로 돌려준다. 연결 실패는 `AuthFlowError`."""

    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:  # noqa: S310
            return HttpResponse(response.status, response.read())
    except urllib.error.HTTPError as exc:
        return HttpResponse(exc.code, exc.read())
    except (urllib.error.URLError, OSError) as exc:
        raise AuthFlowError(f"auth unreachable: {exc}") from exc


# ---------- 설정 ----------


def auth_url() -> str:
    return settings.INFRALAB_AUTH_URL.rstrip("/")


def resource() -> str:
    return f"{settings.PUBLIC_ORIGIN}/api"


def redirect_uri() -> str:
    return f"{settings.PUBLIC_ORIGIN}/api/auth/callback"


def client_configured() -> bool:
    return bool(settings.INFRALAB_AUTH_CLIENT_ID and settings.INFRALAB_AUTH_CLIENT_SECRET)


# ---------- 인가 요청 ----------


class LoginAttempt(TypedDict):
    state: str
    verifier: str
    next: str
    created_at: float


def safe_next(raw: str | None) -> str:
    """같은 사이트 경로만 받는다. `//host`·`/\\host`·제어 문자는 다른 사이트로 새므로 `/`."""

    if not raw or not raw.startswith("/") or raw.startswith("//") or raw.startswith("/\\"):
        return "/"
    if any(ord(c) < 0x20 or c == "\\" for c in raw) or len(raw) > 2000:
        return "/"
    return raw


def new_attempt(next_path: str | None) -> LoginAttempt:
    return LoginAttempt(
        state=secrets.token_urlsafe(32),
        verifier=secrets.token_urlsafe(64),  # 86자 — RFC 7636 의 43~128자 안
        next=safe_next(next_path),
        created_at=time.time(),
    )


def code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def authorize_url(attempt: LoginAttempt) -> str:
    params = {
        "response_type": "code",
        "client_id": settings.INFRALAB_AUTH_CLIENT_ID,
        "redirect_uri": redirect_uri(),
        "state": attempt["state"],
        "code_challenge": code_challenge(attempt["verifier"]),
        "code_challenge_method": "S256",
        "resource": resource(),
        "scope": settings.INFRALAB_AUTH_SCOPE,
    }
    return f"{auth_url()}/authorize?{urllib.parse.urlencode(params)}"


# ---------- 코드 교환 ----------


@dataclass(frozen=True)
class TokenResponse:
    access_token: str
    id_token: str | None


def exchange_code(code: str, verifier: str) -> TokenResponse:
    basic = base64.b64encode(
        f"{urllib.parse.quote(settings.INFRALAB_AUTH_CLIENT_ID, safe='')}:"
        f"{urllib.parse.quote(settings.INFRALAB_AUTH_CLIENT_SECRET, safe='')}".encode()
    ).decode("ascii")
    form = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri(),
            "code_verifier": verifier,
        }
    ).encode()
    res = _http(
        "POST",
        f"{auth_url()}/token",
        {
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        form,
    )
    if res.status != 200:
        raise AuthFlowError(f"token endpoint answered {res.status}")
    try:
        data: JSON = json.loads(res.body)
    except ValueError as exc:
        raise AuthFlowError("token response is not JSON") from exc
    if not isinstance(data, dict) or not isinstance(data.get("access_token"), str):
        raise AuthFlowError("token response has no access_token")
    id_token = data.get("id_token")
    return TokenResponse(access_token=data["access_token"], id_token=id_token if isinstance(id_token, str) else None)


# ---------- JWKS ----------


class _JwksCache:
    """4절: TTL 600초, 모르는 kid 재조회는 60초에 한 번, 실패 뒤 60초 쉰다."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._keys: dict[str, jwt.PyJWK] = {}
        self._fetched_at = 0.0
        self._last_attempt = 0.0

    def clear(self) -> None:
        with self._lock:
            self._keys = {}
            self._fetched_at = 0.0
            self._last_attempt = 0.0

    def _refresh(self, now: float) -> None:
        self._last_attempt = now
        try:
            res = _http("GET", f"{auth_url()}/.well-known/jwks.json", {"Accept": "application/json"})
        except AuthFlowError:
            return
        if res.status != 200:
            return
        try:
            data: JSON = json.loads(res.body)
        except ValueError:
            return
        keys: dict[str, jwt.PyJWK] = {}
        if isinstance(data, dict) and isinstance(data.get("keys"), list):
            for jwk in data["keys"]:
                if not isinstance(jwk, dict) or not isinstance(jwk.get("kid"), str):
                    continue
                if jwk.get("kty") != "OKP" or jwk.get("crv") != "Ed25519":
                    continue
                try:
                    keys[jwk["kid"]] = jwt.PyJWK(jwk, algorithm="EdDSA")
                except jwt.PyJWTError:
                    continue
        self._keys = keys
        self._fetched_at = now

    def key(self, kid: str) -> jwt.PyJWK:
        now = time.monotonic()
        with self._lock:
            stale = not self._fetched_at or now - self._fetched_at > JWKS_TTL_SECONDS
            if stale or kid not in self._keys:
                never_tried = not self._last_attempt
                if never_tried or now - self._last_attempt >= JWKS_REFETCH_MIN_SECONDS:
                    self._refresh(now)
            found = self._keys.get(kid)
        if found is None:
            raise AuthFlowError("unknown kid")
        return found


jwks_cache = _JwksCache()


def _decode(token: str, *, audience: str) -> dict[str, JSON]:
    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as exc:
        raise AuthFlowError("malformed token") from exc
    if header.get("alg") != "EdDSA":
        raise AuthFlowError("alg is not EdDSA")
    kid = header.get("kid")
    if not isinstance(kid, str):
        raise AuthFlowError("no kid")
    key = jwks_cache.key(kid)
    try:
        claims = jwt.decode(
            token,
            key.key,
            algorithms=["EdDSA"],
            audience=audience,
            issuer=auth_url(),
            leeway=EXP_LEEWAY_SECONDS,
            options={"require": ["iss", "sub", "aud", "exp", "iat"], "verify_iat": False, "verify_nbf": False},
        )
    except jwt.PyJWTError as exc:
        raise AuthFlowError(f"token rejected: {exc}") from exc
    # PyJWT 는 배열 aud 도 원소 일치로 받아 준다 — 규칙(T7·T9)은 문자열 완전 일치다.
    if claims.get("aud") != audience or claims.get("iss") != auth_url():
        raise AuthFlowError("aud/iss mismatch")
    if not isinstance(claims.get("sub"), str) or not claims["sub"]:
        raise AuthFlowError("sub is not a string")
    if not isinstance(claims.get("exp"), int) or not isinstance(claims.get("iat"), int):
        raise AuthFlowError("iat/exp are not integers")
    return claims


def verify_access_token(token: str) -> str:
    """액세스 토큰을 검증하고 `sub` 를 돌려준다."""

    claims = _decode(token, audience=resource())
    for name in ("client_id", "scope", "jti"):
        if not isinstance(claims.get(name), str):
            raise AuthFlowError(f"{name} missing")
    scope = claims["scope"]
    assert isinstance(scope, str)
    if REQUIRED_SCOPE not in {s for s in scope.split(" ") if s}:
        raise AuthFlowError("scope lacks infralab")
    sub = claims["sub"]
    assert isinstance(sub, str)
    if "acct" in claims:
        # A2: member 밖(기계 토큰 `machine`, 빈 값, 배열, null …)은 모두 거부.
        if claims["acct"] != "member":
            raise AuthFlowError("acct is not member")
        if not MEMBER_SUB.match(sub):
            raise AuthFlowError("member sub has the wrong shape")
    # acct 가 없으면 대표 토큰(A1). auth 가 대표 계정에만 그런 토큰을 서명한다.
    if len(sub) > MAX_SUB:
        raise AuthFlowError("sub too long")
    return sub


def display_name_from_id_token(id_token: str | None, sub: str) -> str:
    """ID 토큰이 있고, 검증되고, `sub` 가 같을 때만 `name`. 아니면 빈 문자열(로그인은 막지 않는다)."""

    if not id_token:
        return ""
    try:
        claims = _decode(id_token, audience=settings.INFRALAB_AUTH_CLIENT_ID)
    except AuthFlowError:
        return ""
    if claims.get("sub") != sub:
        return ""
    name = claims.get("name")
    return name[:MAX_NAME] if isinstance(name, str) else ""


# ---------- 웹훅 ----------


class WebhookRejected(Exception):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status


def verify_webhook(secret: str, body: bytes, signature_header: str, *, now: float | None = None) -> dict[str, JSON]:
    """W1~W3. 받은 본문 바이트 그대로 검증하고 이벤트를 돌려준다."""

    parts = dict(item.split("=", 1) for item in signature_header.split(",") if "=" in item)
    try:
        timestamp = int(parts["t"])
        given = parts["v1"]
    except (KeyError, ValueError):
        raise WebhookRejected(400, "bad signature header") from None
    current = time.time() if now is None else now
    if abs(current - timestamp) > WEBHOOK_TOLERANCE_SECONDS:
        raise WebhookRejected(400, "stale timestamp")
    expected = hmac.new(secret.encode(), f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, given):
        raise WebhookRejected(401, "bad signature")
    try:
        event: JSON = json.loads(body)
    except ValueError:
        raise WebhookRejected(400, "body is not JSON") from None
    if not isinstance(event, dict) or not isinstance(event.get("id"), str) or not isinstance(event.get("type"), str):
        raise WebhookRejected(400, "event has no id/type")
    return event
