"""소셜 로그인 — 카카오(개발에서는 Fake)로 로그인해 JWT 쌍을 받는다. 비밀번호는 없다."""

import pytest


@pytest.mark.django_db
def test_fake_login_issues_a_token_pair(client):
    res = client.post(
        "/api/auth/social/kakao/login",
        data={"access_token": "uid-1:person@example.com"},
        content_type="application/json",
    )
    assert res.status_code == 200
    body = res.json()
    assert body["access"] and body["refresh"]
    assert body["token_type"] == "bearer"


@pytest.mark.django_db
def test_same_identity_logs_into_the_same_account(api):
    first = api.login("uid-9")
    second = api.login("uid-9")
    assert api.me(first)["id"] == api.me(second)["id"]


@pytest.mark.django_db
def test_different_identities_are_different_accounts_even_with_the_same_email(api):
    a = api.login("uid-a", email="shared@example.com")
    b = api.login("uid-b", email="shared@example.com")
    assert api.me(a)["id"] != api.me(b)["id"]


@pytest.mark.django_db
def test_nickname_becomes_display_name_and_follows_the_latest_login(api):
    s = api.login("uid-n", nickname="말랑카우")
    assert api.me(s)["display_name"] == "말랑카우"
    s = api.login("uid-n", nickname="새별명")
    assert api.me(s)["display_name"] == "새별명"


@pytest.mark.django_db
def test_overlong_nickname_is_cut_not_crashed(api):
    s = api.login("uid-long", nickname="가" * 150)
    assert len(api.me(s)["display_name"]) == 100


@pytest.mark.django_db
def test_overlong_provider_uid_is_rejected(client):
    res = client.post(
        "/api/auth/social/kakao/login",
        data={"access_token": "x" * 200 + ":a@example.com"},
        content_type="application/json",
    )
    assert res.status_code == 401


@pytest.mark.django_db
def test_malformed_fake_token_is_rejected(client):
    res = client.post(
        "/api/auth/social/kakao/login",
        data={"access_token": "not-a-valid-fake-token"},
        content_type="application/json",
    )
    assert res.status_code == 401


@pytest.mark.django_db
def test_unsupported_provider_is_rejected(client):
    res = client.post(
        "/api/auth/social/github/login",
        data={"access_token": "uid-1:a@example.com"},
        content_type="application/json",
    )
    assert res.status_code == 401


@pytest.mark.django_db
def test_me_requires_a_token(client):
    assert client.get("/api/accounts/me").status_code == 401
    assert client.get("/api/accounts/me", HTTP_AUTHORIZATION="Bearer nope").status_code == 401


@pytest.mark.django_db
def test_me_reports_a_plain_student(api):
    s = api.login("uid-s")
    me = api.me(s)
    assert me["username"] == "kakao:uid-s"
    assert me["is_instructor"] is False
