"""리프레시 토큰 회전 — 한 번 쓴 리프레시는 다시 쓸 수 없다."""

import pytest


@pytest.mark.django_db
def test_refresh_returns_a_new_pair_that_works(api):
    s = api.login("uid-r")
    res = api.post("/api/auth/refresh", {"refresh": s.refresh})
    assert res.status_code == 200
    body = res.json()
    assert body["access"] != s.access
    assert body["refresh"] != s.refresh
    from tests.scenarios import Session

    assert api.me(Session(access=body["access"], refresh=body["refresh"]))["username"] == "kakao:uid-r"


@pytest.mark.django_db
def test_used_refresh_token_is_rejected(api):
    s = api.login("uid-r2")
    assert api.post("/api/auth/refresh", {"refresh": s.refresh}).status_code == 200
    assert api.post("/api/auth/refresh", {"refresh": s.refresh}).status_code == 401


@pytest.mark.django_db
def test_inactive_account_cannot_refresh(api):
    from django.contrib.auth import get_user_model

    s = api.login("uid-r4")
    # 비활성화 API 는 없다 — 상태를 직접 만든다.
    get_user_model().objects.filter(username="kakao:uid-r4").update(is_active=False)
    assert api.post("/api/auth/refresh", {"refresh": s.refresh}).status_code == 401
    assert api.get("/api/accounts/me", s).status_code == 401


@pytest.mark.django_db
def test_access_token_cannot_be_used_as_refresh(api):
    s = api.login("uid-r3")
    assert api.post("/api/auth/refresh", {"refresh": s.access}).status_code == 401
