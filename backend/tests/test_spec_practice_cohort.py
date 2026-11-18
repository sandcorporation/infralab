"""연습 묶음 — 연습 종류·데이터 이전·「연습 시작」 참여·모든 시나리오 열림·강사 화면 제외·서로 안 보임.

target: backend/tests/test_spec_practice_cohort.py
AC: #132: 묶음 종류 practice, 데이터 이전이 「개인 연습」 조직(담당자 없음)과 연습 묶음 하나를 만든다. 되돌렸다 다시 돌려도 하나
AC: #132: GET /api/practice 가 연습 묶음 id·이름·joined 를 준다. 연습 묶음이 없으면 만든다 — 언제나 하나
AC: #132: POST /api/practice/join 은 참여를 만들고 다시 눌러도 같은 참여. 로그인 안 했으면 401, 응시 전용 숨은 사용자면 403
AC: #132: 연습 참여자에게 시나리오 목록은 저장소의 모든 시나리오, 상세·환경 준비·compose.yml·제출이 기존 경로로 동작. 참여 안 했으면 404
AC: #132: 연습 사용자끼리 서로의 제출을 보지 못한다
AC: #132: 연습 묶음은 강사 API 에 나오지 않는다(「개인 연습」 조직 담당자여도 목록에 없고 상세·참여자·격자·시나리오 열기 404)
AC: #132: GET /api/cohorts 에 연습 묶음이 없고, GET /api/cohorts/<id> 는 연습 묶음에도 동작하며 kind 를 준다

모든 흐름은 HTTP API 로 본다. 데이터 이전은 cohorts 앱을 `0005_cohort_kind_exam_settings` 로 되감았다 끝까지
돌려 본다(트랜잭션 시험). 다른 시험이 DB 를 비운 뒤에도 연습 묶음이 생기는지는 `GET /api/practice` 로 본다.
"""

import pytest
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import Client

from cohorts.models import Cohort
from orgs.models import Organization, OrgMember
from scenarios import registry
from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

PRACTICE_ORG = "개인 연습"
EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 100000,
}


def _practice(api, session) -> dict:
    res = api.get("/api/practice", session)
    assert res.status_code == 200, res.content
    return res.json()


def _start(api, session) -> dict:
    res = api.post("/api/practice/join", session=session)
    assert res.status_code == 200, res.content
    return res.json()


def _submit(api, session, cohort_id, passing):
    res = api.post(
        f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions",
        {"agent_version": "0.9.0", "results": s3_results(passing)},
        session,
    )
    assert res.status_code == 201, res.content
    return res.json()


# ---------- 데이터 이전 ----------


@pytest.mark.django_db(transaction=True)
def test_migration_makes_one_practice_cohort_in_an_org_without_staff():
    executor = MigrationExecutor(connection)
    executor.migrate([("cohorts", "0005_cohort_kind_exam_settings")])
    executor = MigrationExecutor(connection)
    executor.migrate(executor.loader.graph.leaf_nodes())

    practice = list(Cohort.objects.filter(kind="practice"))
    assert len(practice) == 1
    assert practice[0].org.name == PRACTICE_ORG
    assert not OrgMember.objects.filter(org=practice[0].org).exists()

    # 되돌렸다 다시 돌려도 하나.
    executor = MigrationExecutor(connection)
    executor.migrate([("cohorts", "0005_cohort_kind_exam_settings")])
    executor = MigrationExecutor(connection)
    executor.migrate(executor.loader.graph.leaf_nodes())
    assert Cohort.objects.filter(kind="practice").count() == 1
    assert Organization.objects.filter(name=PRACTICE_ORG).count() == 1


def test_practice_kind_is_a_cohort_kind():
    assert Cohort.Kind.PRACTICE == "practice"


# ---------- 연습 시작 ----------


@pytest.mark.django_db
def test_practice_status_names_the_single_practice_cohort(api):
    u = api.login("p1")

    status = _practice(api, u)
    again = _practice(api, api.login("p2"))

    assert status["joined"] is False
    assert status["scenario_count"] == len(registry.all_scenarios())
    assert again["cohort_id"] == status["cohort_id"]
    assert Cohort.objects.filter(kind="practice").count() == 1
    cohort = Cohort.objects.get(pk=status["cohort_id"])
    assert cohort.kind == "practice" and cohort.org.name == PRACTICE_ORG
    assert status["name"] == cohort.name


@pytest.mark.django_db
def test_start_practice_joins_once_and_again_is_the_same_membership(api):
    u = api.login("p1")
    pid = _practice(api, u)["cohort_id"]

    first = _start(api, u)
    assert (first["cohort_id"], first["created"]) == (pid, True)
    assert _practice(api, u)["joined"] is True
    token = api.get(f"/api/cohorts/{pid}", u).json()["agent_token"]

    second = _start(api, u)
    assert (second["cohort_id"], second["created"]) == (pid, False)
    assert api.get(f"/api/cohorts/{pid}", u).json()["agent_token"] == token
    assert Cohort.objects.get(pk=pid).memberships.filter(user__username="sandcorp:p1").count() == 1


@pytest.mark.django_db
def test_start_practice_needs_login(api):
    assert api.get("/api/practice").status_code == 401
    assert api.post("/api/practice/join").status_code == 401


@pytest.mark.django_db
def test_exam_only_hidden_user_cannot_join_practice(api):
    teacher = api.login_instructor()
    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    exam = res.json()
    assert api.put(f"/api/instructor/cohorts/{exam['id']}/exam-settings", EXAM_SETTINGS, teacher).status_code == 200
    res = api.post(f"/api/instructor/cohorts/{exam['id']}/exam-invites", {"label": "지원자"}, teacher)
    assert res.status_code == 201, res.content
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{res.json()['token']}/enter", session=cand).status_code == 200

    assert api.post("/api/practice/join", session=cand).status_code == 403
    pid = _practice(api, api.login("p1"))["cohort_id"]
    assert not Cohort.objects.get(pk=pid).memberships.filter(user__username__startswith="exam-invite:").exists()


# ---------- 연습 묶음에서 시나리오 ----------


@pytest.mark.django_db
def test_practice_cohort_shows_every_scenario_in_the_repository(api):
    u = api.login("p1")
    pid = _start(api, u)["cohort_id"]

    res = api.get(f"/api/cohorts/{pid}/scenarios", u)

    assert res.status_code == 200, res.content
    ids = [s["id"] for s in res.json()]
    assert sorted(ids) == sorted(registry.all_scenarios()) and len(ids) == len(set(ids))
    assert all(s["passed"] is None for s in res.json())


@pytest.mark.django_db
def test_practice_member_uses_the_existing_scenario_paths(api):
    u = api.login("p1")
    pid = _start(api, u)["cohort_id"]

    detail = api.get(f"/api/cohorts/{pid}/scenarios/{S3}", u)
    assert detail.status_code == 200, detail.content
    assert [c["id"] for c in detail.json()["checks"]] == S3_CHECK_IDS
    assert api.get(f"/api/cohorts/{pid}/scenarios/{S3}/prepare", u).status_code == 200
    compose = api.get(f"/api/cohorts/{pid}/compose.yml", u)
    assert compose.status_code == 200
    assert api.get(f"/api/cohorts/{pid}", u).json()["agent_token"] in compose.content.decode()

    sub = _submit(api, u, pid, {"bucket-exists"})
    assert (sub["passed"], sub["total"]) == (1, 4)
    latest = api.get(f"/api/cohorts/{pid}/scenarios/{S3}/submissions/latest", u).json()
    assert latest["id"] == sub["id"]
    listed = api.get(f"/api/cohorts/{pid}/scenarios", u).json()
    assert next(s for s in listed if s["id"] == S3)["passed"] == 1


@pytest.mark.django_db
def test_practice_paths_are_404_before_joining(api):
    u = api.login("p1")
    pid = _practice(api, u)["cohort_id"]

    assert api.get(f"/api/cohorts/{pid}", u).status_code == 404
    assert api.get(f"/api/cohorts/{pid}/scenarios", u).status_code == 404
    assert api.get(f"/api/cohorts/{pid}/scenarios/{S3}", u).status_code == 404
    res = api.post(
        f"/api/cohorts/{pid}/scenarios/{S3}/submissions",
        {"agent_version": "0.9.0", "results": s3_results(set(S3_CHECK_IDS))},
        u,
    )
    assert res.status_code == 404


@pytest.mark.django_db
def test_practice_users_do_not_see_each_others_submissions(api):
    a, b = api.login("pa"), api.login("pb")
    pid = _start(api, a)["cohort_id"]
    _start(api, b)
    _submit(api, a, pid, set(S3_CHECK_IDS))

    assert api.get(f"/api/cohorts/{pid}/scenarios/{S3}/submissions", b).json() == []
    assert api.get(f"/api/cohorts/{pid}/scenarios/{S3}/submissions/latest", b).status_code == 404
    listed = api.get(f"/api/cohorts/{pid}/scenarios", b).json()
    assert next(s for s in listed if s["id"] == S3)["passed"] is None
    assert len(api.get(f"/api/cohorts/{pid}/scenarios/{S3}/submissions", a).json()) == 1


# ---------- 강사 화면·내 기수 목록 ----------


@pytest.mark.django_db
def test_practice_cohort_is_not_on_the_instructor_surface_even_for_its_org_staff(api):
    student = api.login("p1")
    pid = _start(api, student)["cohort_id"]
    sub = _submit(api, student, pid, {"bucket-exists"})
    operator = api.login_instructor("operator", org=PRACTICE_ORG)
    own = api.create_cohort(api.login_instructor("teacher"), "1기")

    cohorts = api.get("/api/instructor/cohorts", operator)
    assert cohorts.status_code == 200
    assert pid not in [c["id"] for c in cohorts.json()]
    assert api.get(f"/api/instructor/cohorts/{pid}", operator).status_code == 404
    assert api.get(f"/api/instructor/cohorts/{pid}/participants", operator).status_code == 404
    assert api.get(f"/api/instructor/cohorts/{pid}/grid", operator).status_code == 404
    assert api.put(f"/api/instructor/cohorts/{pid}/scenarios", {"scenario_ids": [S3]}, operator).status_code == 404
    assert api.patch(f"/api/instructor/cohorts/{pid}", {"archived": True}, operator).status_code == 404
    assert api.get(f"/api/instructor/submissions/{sub['id']}", operator).status_code == 404
    # 다른 조직의 기수는 지금처럼 보이지 않는다(연습 제외가 남의 기수를 끌어오지 않는다).
    assert own["id"] not in [c["id"] for c in cohorts.json()]


@pytest.mark.django_db
def test_my_cohorts_leaves_out_practice_but_detail_gives_kind(api):
    teacher = api.login_instructor()
    klass = api.create_cohort(teacher, "1기")
    u = api.login("p1")
    api.join(u, klass["join_token"])
    pid = _start(api, u)["cohort_id"]

    mine = api.get("/api/cohorts", u).json()
    assert [c["id"] for c in mine] == [klass["id"]]

    only_practice = api.login("p2")
    _start(api, only_practice)
    assert api.get("/api/cohorts", only_practice).json() == []

    detail = api.get(f"/api/cohorts/{pid}", u)
    assert detail.status_code == 200
    assert detail.json()["kind"] == "practice"
    assert api.get(f"/api/cohorts/{klass['id']}", u).json()["kind"] == "class"
