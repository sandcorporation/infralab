"""응시 링크를 연 브라우저의 세션 넘기기(#122) — 로그인된 브라우저에서 enter 뒤 401·세션 쿠키가 사라지던 일.

근본 원인: 다른 사용자로 로그인된 브라우저에서 enter 의 `login()` 은 그 세션을 지우고(flush) 새 키를 준다. 같은 때 옛 쿠키로 나간 요청은
빈 세션을 읽어 401 이 되고, Django SessionMiddleware 는 「쿠키가 왔는데 세션이 비었다」며 응답에서 세션 쿠키를
지운다 — 그 응답이 enter 의 Set-Cookie 보다 늦게 닿으면 새 응시 세션 쿠키까지 지워진다.

지원자는 계정·기수 가입 없이 응시 링크만으로 끝까지 간다(스펙 #62) — 숨은 응시 사용자 세션으로 내 기수·설치
안내·compose.yml·시나리오가 되는지, 쿠키 없이 응시 토큰만으로 받는 compose 주소도 여기서 본다.
"""

import pytest
from django.conf import settings
from django.test import Client

from tests.api_helpers import S3, Session
from tests.test_spec_exam_attempt import _browser, _enter, _expire, _setup, _start

pytestmark = pytest.mark.django_db

COOKIE = settings.SESSION_COOKIE_NAME


def _key(session: Session) -> str:
    return session.client.cookies[COOKIE].value


def _with_cookie(key: str) -> Client:
    client = Client()
    client.cookies[COOKIE] = key
    return client


def test_request_with_the_pre_enter_cookie_deletes_the_session_cookie(api):
    """원인 재현 — 다른 사용자(강사)로 로그인된 브라우저에서 enter 하면 옛 쿠키 요청은 401 이고 쿠키를 지우라고 답한다."""

    teacher, cohort, invite = _setup(api)
    old = _key(teacher)
    teacher_id = api.me(teacher)["id"]

    body = _enter(api, teacher, invite["token"])

    assert _key(teacher) != old
    assert body["replaced_login"] is True
    stale = _with_cookie(old).get("/api/accounts/me")
    assert stale.status_code == 401
    assert stale.cookies[COOKIE].value == "" and stale.cookies[COOKIE]["max-age"] == 0
    # 새 쿠키로는 숨은 응시 사용자다.
    assert api.me(teacher)["id"] != teacher_id
    # 그 401 응답이 enter 의 Set-Cookie 뒤에 닿은 브라우저 — 새 응시 세션 쿠키가 지워져 이후 요청이 모두 401.
    teacher.client.cookies.update(stale.cookies)
    assert teacher.client.get("/api/accounts/me").status_code == 401


def test_reopening_the_link_keeps_the_candidate_session(api):
    """같은 응시 사용자로 다시 열면 세션을 돌리지 않는다 — 함께 나간 요청이 옛 쿠키로 401·쿠키 지우기를 받지 않게."""

    teacher, cohort, invite = _setup(api)
    cand = _browser()
    first = _enter(api, cand, invite["token"])
    key = _key(cand)

    again = _enter(api, cand, invite["token"])

    assert first["replaced_login"] is False and again["replaced_login"] is False
    assert _key(cand) == key
    res = _with_cookie(key).get(f"/api/cohorts/{cohort['id']}")
    assert res.status_code == 200, res.content
    assert COOKIE not in res.cookies


def test_hidden_candidate_reaches_cohort_setup_compose_and_scenarios(api):
    """가입 없이 응시 링크 세션만으로 내 기수·설치 안내(compose.yml)·시작·시나리오까지 간다."""

    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])

    assert [c["id"] for c in api.get("/api/cohorts", cand).json()] == [cohort["id"]]
    detail = api.get(f"/api/cohorts/{cohort['id']}", cand)
    assert detail.status_code == 200, detail.content
    compose = api.get(f"/api/cohorts/{cohort['id']}/compose.yml", cand)
    assert compose.status_code == 200
    assert detail.json()["agent_token"] in compose.content.decode()

    _start(api, cand, invite["token"])
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}", cand).status_code == 200


def test_exam_compose_url_needs_only_the_exam_token(api):
    teacher, cohort, invite = _setup(api)
    url = f"/api/exam/{invite['token']}/compose.yml"
    assert Client().get(url).status_code == 409  # enter 전에는 응시자가 없다

    cand = _browser()
    _enter(api, cand, invite["token"])
    agent_token = api.get(f"/api/cohorts/{cohort['id']}", cand).json()["agent_token"]

    res = Client().get(url)  # 설치 프로그램 — 쿠키 없음
    assert res.status_code == 200, res.content
    assert res["Content-Type"].startswith("text/yaml")
    assert agent_token in res.content.decode()
    assert Client().get("/api/exam/notatoken/compose.yml").status_code == 404


def test_exam_compose_url_is_gone_after_finish_and_404_when_revoked(api):
    teacher, cohort, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    _start(api, cand, invite["token"])
    url = f"/api/exam/{invite['token']}/compose.yml"
    assert Client().get(url).status_code == 200

    _expire(invite["id"])
    assert Client().get(url).status_code == 410
    # 끝난 응시는 회수되지 않는다(#154) — 그대로 410.
    invites = f"/api/instructor/cohorts/{cohort['id']}/exam-invites"
    assert api.delete(f"{invites}/{invite['id']}", teacher).status_code == 409
    assert Client().get(url).status_code == 410

    # 진행 중에 회수한 응시는 404.
    other = api.post(invites, {"label": "지원자 B"}, teacher).json()
    cand2 = _browser()
    _enter(api, cand2, other["token"])
    _start(api, cand2, other["token"])
    other_url = f"/api/exam/{other['token']}/compose.yml"
    assert Client().get(other_url).status_code == 200
    assert api.delete(f"{invites}/{other['id']}", teacher).status_code == 204
    assert Client().get(other_url).status_code == 404
