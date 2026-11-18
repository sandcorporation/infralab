"""sandcorp-auth 로그인 — 기밀 클라이언트·PKCE·JWKS 검증·세션 쿠키·로그아웃·탈퇴 웹훅.

바깥 auth 서버는 `FakeAuth` 가 대신한다(네트워크 없음). 실제 auth 처럼 조건부로 굴러간다:
/token 은 Basic 자격·코드 1회·redirect_uri·PKCE verifier 를 확인하고, ID 토큰은 `openid` 를 요청했을 때만,
`name` 은 `profile` 일 때만 준다.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
import urllib.parse
from dataclasses import dataclass, field

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from django.conf import settings
from django.contrib.auth import get_user_model
from django.test import Client, override_settings

from accounts import sandcorp_auth
from tests.api_helpers import dashboard_origin

AUTH = "https://auth.example.test"
CLIENT_ID = "infralab-test-client"
CLIENT_SECRET = "test-only-client-secret"
WEBHOOK_SECRET = "test-only-webhook-secret"
MEMBER = "m_01JB2Z3Y4X5W6V7T8S9R0Q1P2N"
OTHER_MEMBER = "m_01JB2Z3Y4X5W6V7T8S9R0Q1P2M"


def _jwk(key: Ed25519PrivateKey, kid: str) -> dict:
    jwk = json.loads(jwt.algorithms.OKPAlgorithm.to_jwk(key.public_key()))
    return {**jwk, "kid": kid, "use": "sig", "alg": "EdDSA"}


@dataclass
class Grant:
    challenge: str
    redirect_uri: str
    scope: set[str]
    sub: str
    used: bool = False


@dataclass
class FakeAuth:
    key: Ed25519PrivateKey = field(default_factory=Ed25519PrivateKey.generate)
    kid: str = "k1"
    grants: dict[str, Grant] = field(default_factory=dict)
    #: 다음 액세스·ID 토큰 클레임에 덮어쓸 값(None 이면 그 클레임을 뺀다).
    access_overrides: dict = field(default_factory=dict)
    id_overrides: dict = field(default_factory=dict)
    #: 액세스 토큰을 이 키로 서명한다(JWKS 에 없는 키 → 서명 실패).
    signing_key: Ed25519PrivateKey | None = None
    name: str = "김철수"

    # 브라우저가 /authorize 에서 동의하고 돌아오는 몫.
    def authorize(self, location: str, sub: str = MEMBER) -> dict[str, str]:
        url = urllib.parse.urlsplit(location)
        assert f"{url.scheme}://{url.netloc}{url.path}" == f"{AUTH}/authorize"
        q = dict(urllib.parse.parse_qsl(url.query))
        assert q["client_id"] == CLIENT_ID and q["code_challenge_method"] == "S256"
        code = secrets.token_urlsafe(16)
        self.grants[code] = Grant(q["code_challenge"], q["redirect_uri"], set(q["scope"].split()), sub)
        return {"code": code, "state": q["state"]}

    def _sign(self, claims: dict, key: Ed25519PrivateKey | None = None) -> str:
        return jwt.encode(claims, key or self.key, algorithm="EdDSA", headers={"kid": self.kid})

    def _token(self, headers: dict[str, str], body: bytes) -> sandcorp_auth.HttpResponse:
        basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
        if headers.get("Authorization") != f"Basic {basic}":
            return sandcorp_auth.HttpResponse(401, b'{"error":"invalid_client"}')
        form = dict(urllib.parse.parse_qsl(body.decode()))
        grant = self.grants.get(form.get("code", ""))
        if (
            form.get("grant_type") != "authorization_code"
            or grant is None
            or grant.used
            or grant.redirect_uri != form.get("redirect_uri")
            or sandcorp_auth.code_challenge(form.get("code_verifier", "")) != grant.challenge
        ):
            return sandcorp_auth.HttpResponse(400, b'{"error":"invalid_grant"}')
        grant.used = True
        now = int(time.time())
        resource_scopes = grant.scope - {"openid", "profile", "email"}
        access = {
            "iss": AUTH,
            "sub": grant.sub,
            "aud": f"{settings.PUBLIC_ORIGIN}/api",
            "client_id": CLIENT_ID,
            "scope": " ".join(sorted(resource_scopes)),
            "iat": now,
            "exp": now + 600,
            "jti": secrets.token_hex(8),
            "acct": "member",
        }
        access = {k: v for k, v in {**access, **self.access_overrides}.items() if v is not None}
        out = {"access_token": self._sign(access, self.signing_key), "token_type": "Bearer", "expires_in": 600}
        if "openid" in grant.scope:
            idt = {"iss": AUTH, "sub": grant.sub, "aud": CLIENT_ID, "iat": now, "exp": now + 600, "acct": "member"}
            if "profile" in grant.scope:
                idt["name"] = self.name
            idt = {k: v for k, v in {**idt, **self.id_overrides}.items() if v is not None}
            out["id_token"] = self._sign(idt)
        return sandcorp_auth.HttpResponse(200, json.dumps(out).encode())

    def http(self, method: str, url: str, headers: dict[str, str], body: bytes | None = None):
        if method == "GET" and url == f"{AUTH}/.well-known/jwks.json":
            return sandcorp_auth.HttpResponse(200, json.dumps({"keys": [_jwk(self.key, self.kid)]}).encode())
        if method == "POST" and url == f"{AUTH}/token":
            return self._token(headers, body or b"")
        return sandcorp_auth.HttpResponse(404, b"")


@pytest.fixture
def fake(monkeypatch):
    auth = FakeAuth()
    monkeypatch.setattr(sandcorp_auth, "_http", auth.http)
    sandcorp_auth.jwks_cache.clear()
    with override_settings(
        INFRALAB_AUTH_URL=AUTH,
        INFRALAB_AUTH_CLIENT_ID=CLIENT_ID,
        INFRALAB_AUTH_CLIENT_SECRET=CLIENT_SECRET,
        INFRALAB_AUTH_WEBHOOK_SECRET=WEBHOOK_SECRET,
        INFRALAB_AUTH_SCOPE="openid profile infralab",
    ):
        yield auth
    sandcorp_auth.jwks_cache.clear()


def _start(client: Client, next_path: str = "/instructor") -> str:
    res = client.get("/api/auth/login", {"next": next_path})
    assert res.status_code == 302
    return res["Location"]


def _finish(client: Client, params: dict[str, str]):
    return client.get("/api/auth/callback", params)


def _login(fake: FakeAuth, client: Client | None = None, sub: str = MEMBER, next_path: str = "/instructor"):
    client = client or Client()
    res = _finish(client, fake.authorize(_start(client, next_path), sub=sub))
    return client, res


def _me(client: Client):
    return client.get("/api/accounts/me")


def _failed() -> str:
    return f"{settings.PUBLIC_ORIGIN}/login?error=1"


# ---------- 인가 요청 ----------


@pytest.mark.django_db
def test_login_redirects_to_authorize_with_pkce_and_keeps_the_verifier_server_side(fake):
    client = Client()
    location = _start(client)
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(location).query))
    assert q["response_type"] == "code"
    assert q["client_id"] == CLIENT_ID
    assert q["redirect_uri"] == f"{settings.PUBLIC_ORIGIN}/api/auth/callback"
    assert q["resource"] == f"{settings.PUBLIC_ORIGIN}/api"
    assert q["scope"] == "openid profile infralab"
    assert q["code_challenge_method"] == "S256"
    attempt = client.session["infralab.login_attempt"]
    verifier = attempt["verifier"]
    assert 43 <= len(verifier) <= 128
    assert verifier not in location
    assert all(verifier not in c.value for c in client.cookies.values())
    expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    assert q["code_challenge"] == expected
    assert q["state"] == attempt["state"]


@pytest.mark.django_db
def test_requested_scope_follows_the_setting(fake):
    with override_settings(INFRALAB_AUTH_SCOPE="infralab"):
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(_start(Client())).query))
    assert q["scope"] == "infralab"


@pytest.mark.django_db
def test_login_is_503_without_client_credentials(fake, client):
    with override_settings(INFRALAB_AUTH_CLIENT_ID=""):
        assert client.get("/api/auth/login").status_code == 503
    assert client.get("/api/health").status_code == 200


# ---------- 콜백 ----------


@pytest.mark.django_db
def test_callback_creates_the_user_opens_a_session_and_returns_to_next(fake):
    client, res = _login(fake)
    assert res.status_code == 302
    assert res["Location"] == f"{settings.PUBLIC_ORIGIN}/instructor"
    cookie = client.cookies[settings.SESSION_COOKIE_NAME]
    assert cookie["httponly"] and cookie["samesite"] == "Lax"
    me = _me(client).json()
    assert me["username"] == f"sandcorp:{MEMBER}"
    assert me["display_name"] == "김철수"
    assert "infralab.login_attempt" not in client.session


@pytest.mark.django_db
def test_same_sub_logs_into_the_same_user_and_name_follows_the_latest_login(fake):
    a, _ = _login(fake)
    fake.name = "새이름"
    b, _ = _login(fake)
    assert _me(a).json()["id"] == _me(b).json()["id"]
    assert _me(b).json()["display_name"] == "새이름"
    other, _ = _login(fake, sub=OTHER_MEMBER)
    assert _me(other).json()["id"] != _me(a).json()["id"]


@pytest.mark.django_db
def test_login_without_an_id_token_uses_only_the_sub(fake):
    with override_settings(INFRALAB_AUTH_SCOPE="infralab"):
        client, res = _login(fake)
    assert res["Location"] == f"{settings.PUBLIC_ORIGIN}/instructor"
    me = _me(client).json()
    assert me["username"] == f"sandcorp:{MEMBER}"
    assert me["display_name"] == ""


@pytest.mark.django_db
def test_id_token_name_is_ignored_when_its_sub_differs(fake):
    fake.id_overrides = {"sub": OTHER_MEMBER}
    client, res = _login(fake)
    assert res["Location"].endswith("/instructor")
    assert _me(client).json()["display_name"] == ""


@pytest.mark.django_db
def test_state_mismatch_is_rejected(fake):
    client = Client()
    params = fake.authorize(_start(client))
    res = _finish(client, {**params, "state": "not-the-state"})
    assert res["Location"] == _failed()
    assert _me(client).status_code == 401


@pytest.mark.django_db
def test_an_attempt_is_used_once(fake):
    client = Client()
    params = fake.authorize(_start(client))
    assert _finish(client, params)["Location"].endswith("/instructor")
    assert _finish(client, params)["Location"] == _failed()


@pytest.mark.django_db
def test_error_parameter_fails_the_login(fake):
    client = Client()
    params = fake.authorize(_start(client))
    res = _finish(client, {**params, "error": "access_denied"})
    assert res["Location"] == _failed()
    assert _me(client).status_code == 401


@pytest.mark.django_db
def test_expired_attempt_is_rejected(fake, monkeypatch):
    client = Client()
    params = fake.authorize(_start(client))
    real = time.time
    monkeypatch.setattr("accounts.api.time.time", lambda: real() + 601)
    assert _finish(client, params)["Location"] == _failed()


@pytest.mark.django_db
def test_callback_without_a_started_attempt_is_rejected(fake):
    assert _finish(Client(), {"code": "x", "state": "y"})["Location"] == _failed()


BAD_ACCESS_TOKENS = {
    "iss": {"iss": AUTH + "/"},
    "aud": {"aud": "https://other.example.test/api"},
    "aud-array": {"aud": ["__RESOURCE__"]},
    "exp": {},  # 시험 안에서 지금 시각으로 채운다
    "scope": {"scope": "infralabx login"},
    "member-sub": {"sub": "m_not-a-ulid"},
    "machine": {"acct": "machine", "sub": f"client:{CLIENT_ID}"},
    "acct-null-ish": {"acct": ""},
    "no-jti": {"jti": None},
}


@pytest.mark.django_db
@pytest.mark.parametrize("case", sorted(BAD_ACCESS_TOKENS))
def test_invalid_access_tokens_are_rejected(fake, case):
    overrides = dict(BAD_ACCESS_TOKENS[case])
    if overrides.get("aud") == ["__RESOURCE__"]:
        overrides["aud"] = [f"{settings.PUBLIC_ORIGIN}/api"]
    if case == "exp":
        now = int(time.time())
        overrides = {"exp": now - 31, "iat": now - 700}
    fake.access_overrides = overrides
    client, res = _login(fake)
    assert res["Location"] == _failed()
    assert _me(client).status_code == 401
    assert not get_user_model().objects.filter(username__startswith="sandcorp:").exists()


@pytest.mark.django_db
def test_access_token_signed_by_an_unknown_key_is_rejected(fake):
    fake.signing_key = Ed25519PrivateKey.generate()
    client, res = _login(fake)
    assert res["Location"] == _failed()
    assert _me(client).status_code == 401


@pytest.mark.django_db
def test_owner_token_without_acct_is_accepted(fake):
    fake.access_overrides = {"acct": None, "sub": "owner-name"}
    fake.id_overrides = {"sub": "owner-name"}
    client, res = _login(fake, sub="owner-name")
    assert res["Location"].endswith("/instructor")
    assert _me(client).json()["username"] == "sandcorp:owner-name"


@pytest.mark.django_db
@pytest.mark.parametrize("bad_next", ["//evil.example", "https://evil.example/x", "/\\evil.example", "evil"])
def test_next_must_be_a_same_site_path(fake, bad_next):
    _, res = _login(fake, next_path=bad_next)
    assert res["Location"] == f"{settings.PUBLIC_ORIGIN}/"


# ---------- 세션 · CSRF · 로그아웃 ----------


@pytest.mark.django_db
def test_cookie_requests_that_change_state_need_the_dashboard_origin(fake):
    client, _ = _login(fake)
    no_origin = client.post("/api/join/whatever", content_type="application/json")
    other = client.post("/api/join/whatever", content_type="application/json", HTTP_ORIGIN="https://evil.example")
    assert no_origin.status_code == 403
    assert other.status_code == 403
    allowed = client.post("/api/join/whatever", content_type="application/json", HTTP_ORIGIN=dashboard_origin())
    assert allowed.status_code == 404  # 인증·출처는 통과했고, 그런 참가 토큰은 없다


@pytest.mark.django_db
def test_logout_ends_the_session(fake):
    client, _ = _login(fake)
    assert _me(client).status_code == 200
    assert client.post("/api/auth/logout", HTTP_ORIGIN=dashboard_origin()).status_code == 204
    assert _me(client).status_code == 401


@pytest.mark.django_db
def test_logout_needs_the_dashboard_origin(fake):
    client, _ = _login(fake)
    assert client.post("/api/auth/logout").status_code == 403
    assert _me(client).status_code == 200


# ---------- 개발용 로그인 ----------


@pytest.mark.django_db
def test_dev_login_is_404_in_production(client):
    with override_settings(DEV_LOGIN_ENABLED=False):
        res = client.post("/api/auth/dev-login", {"uid": "x"}, content_type="application/json")
    assert res.status_code == 404
    assert _me(client).status_code == 401


@pytest.mark.django_db
def test_dev_login_nickname_follows_the_latest_login(api):
    s = api.login("uid-n", nickname="말랑카우")
    assert api.me(s)["display_name"] == "말랑카우"
    s = api.login("uid-n", nickname="새별명")
    assert api.me(s)["display_name"] == "새별명"
    assert api.me(s)["username"] == "sandcorp:uid-n"
    assert api.me(s)["is_instructor"] is False


@pytest.mark.django_db
def test_me_requires_a_session(client):
    assert client.get("/api/accounts/me").status_code == 401
    assert client.get("/api/accounts/me", HTTP_AUTHORIZATION="Bearer nope").status_code == 401


# ---------- 탈퇴 웹훅 ----------


def _signed(body: bytes, *, t: int | None = None, secret: str = WEBHOOK_SECRET) -> dict[str, str]:
    t = int(time.time()) if t is None else t
    v1 = hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()
    return {"HTTP_X_SANDCORP_SIGNATURE": f"t={t},v1={v1}"}


def _event(event_id: str = "01JB0Z8F3W4Q2Y6K7M9N0P1R2S", type_: str = "user.deleted", sub: str = MEMBER) -> bytes:
    # 공백 섞인 직렬화 — 서버가 다시 직렬화해 검증하면 서명이 어긋난다.
    return (
        f'{{"id": "{event_id}", "type": "{type_}", "sub": "{sub}", "occurred_at": "2026-11-18T03:15:00Z"}}'
    ).encode()


def _hook(client: Client, body: bytes, headers: dict[str, str]):
    return client.post("/api/auth/webhook", data=body, content_type="application/json", **headers)


@pytest.mark.django_db
def test_webhook_user_deleted_deactivates_the_user_and_ends_sessions(fake, client):
    session, _ = _login(fake)
    body = _event()
    assert _hook(client, body, _signed(body)).status_code == 204
    assert _me(session).status_code == 401
    user = get_user_model().objects.get(username=f"sandcorp:{MEMBER}")
    assert user.is_active is False and user.display_name == ""
    # 같은 이벤트 재전송은 2xx(W4).
    assert _hook(client, body, _signed(body)).status_code == 204
    # 탈퇴한 sub 로는 다시 들어오지 못한다.
    again, res = _login(fake)
    assert res["Location"] == _failed()


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("headers", "status"),
    [
        ({}, 400),
        ({"HTTP_X_SANDCORP_SIGNATURE": "garbage"}, 400),
        ("stale", 400),
        ("wrong-secret", 401),
        ("tampered", 401),
    ],
)
def test_webhook_rejects_bad_signatures(fake, client, headers, status):
    session, _ = _login(fake)
    body = _event()
    if headers == "stale":
        headers = _signed(body, t=int(time.time()) - 301)
    elif headers == "wrong-secret":
        headers = _signed(body, secret="not-the-secret")
    elif headers == "tampered":
        headers = _signed(body.replace(b"user.deleted", b"user.deletex"))
    assert _hook(client, body, headers).status_code == status
    assert _me(session).status_code == 200


@pytest.mark.django_db
def test_webhook_ignores_unknown_event_types(fake, client):
    session, _ = _login(fake)
    body = _event(event_id="01JB0Z8F3W4Q2Y6K7M9N0P1R2T", type_="user.renamed")
    assert _hook(client, body, _signed(body)).status_code == 204
    assert _me(session).status_code == 200
