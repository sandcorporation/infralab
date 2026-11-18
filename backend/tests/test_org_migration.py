"""조직 이전 — 조직 없던 시절의 기수·강사·학생·제출이 이전 뒤에도 그대로 동작한다.

이전 전 상태(cohorts 0001, orgs 없음)로 DB 를 되감고 옛 모델로 데이터를 만든 뒤, 이전을 끝까지 돌리고
공개 API 로 확인한다.
"""

import pytest
from django.db import connection
from django.db.migrations.executor import MigrationExecutor

from tests.api_helpers import S3, S3_CHECK_IDS

BEFORE = [("cohorts", "0001_initial"), ("orgs", None)]
#: 이전 전 모델 상태 — orgs 가 없고, 제출 앱은 그때의 최신.
BEFORE_STATE = [("cohorts", "0001_initial"), ("submissions", "0002_submission_ai_transcript")]


def _migrate(targets):
    executor = MigrationExecutor(connection)
    executor.migrate(targets)


def _before():
    _migrate(BEFORE)
    return MigrationExecutor(connection).loader.project_state(BEFORE_STATE).apps


def _stored_results(passing: set[str]) -> list[dict]:
    """DB 에 저장된 제출 결과의 모양(submissions.api 가 만드는 것)."""

    return [
        {"check_id": cid, "name": cid, "pass": cid in passing, "output": "", "truncated": False, "exit_code": 0, "error": ""}
        for cid in S3_CHECK_IDS
    ]


def _latest():
    executor = MigrationExecutor(connection)
    return executor.loader.graph.leaf_nodes()


@pytest.mark.django_db(transaction=True)
def test_migration_keeps_the_running_class_working(api):
    old = _before()
    User = old.get_model("accounts", "User")
    Cohort = old.get_model("cohorts", "Cohort")
    Membership = old.get_model("cohorts", "Membership")
    Submission = old.get_model("submissions", "Submission")

    User.objects.create(username="sandcorp:teacher", is_instructor=True)
    student = User.objects.create(username="sandcorp:student")
    c1 = Cohort.objects.create(name="1기", open_scenario_ids=[S3])
    c2 = Cohort.objects.create(name="2기", join_open=True)
    m = Membership.objects.create(user=student, cohort=c1)
    sub = Submission.objects.create(
        membership=m, scenario_id=S3, agent_version="0.4.0", passed=1, total=4, results=_stored_results({"bucket-exists"})
    )
    old_ids = {c1.id, c2.id}
    join_token_2, agent_token = c2.join_token, m.agent_token

    _migrate(_latest())

    teacher = api.login("teacher")
    me = api.me(teacher)
    assert me["is_instructor"] is True
    assert [(o["name"], o["role"]) for o in me["orgs"]] == [("기본 조직", "owner")]

    # 강사는 두 기수를 그대로 보고 관리한다.
    cohorts = api.get("/api/instructor/cohorts", teacher).json()
    assert {c["id"] for c in cohorts} == old_ids
    res = api.patch(f"/api/instructor/cohorts/{c2.id}", {"name": "2기(이름 변경)"}, teacher)
    assert res.status_code == 200 and res.json()["name"] == "2기(이름 변경)"

    # 제출 조회: 격자·상세.
    grid = api.get(f"/api/instructor/cohorts/{c1.id}/grid", teacher).json()
    cell = grid["rows"][0]["cells"][S3]
    assert (cell["submission_id"], cell["passed"], cell["total"]) == (sub.id, 1, 4)
    assert api.get(f"/api/instructor/submissions/{sub.id}", teacher).status_code == 200

    # 학생: 옛 에이전트 토큰 그대로, 옛 가입 링크로 다른 기수에 들어간다.
    s = api.login("student")
    assert api.get(f"/api/cohorts/{c1.id}", s).json()["agent_token"] == agent_token
    assert api.join(s, join_token_2)["cohort_id"] == c2.id
    assert api.get(f"/api/cohorts/{c1.id}/scenarios", s).json()[0]["passed"] == 1


@pytest.mark.django_db(transaction=True)
def test_migration_on_an_empty_database_creates_no_org(api):
    old = _before()
    old.get_model("accounts", "User").objects.create(username="sandcorp:plain")

    _migrate(_latest())

    s = api.login("plain")
    assert api.me(s)["orgs"] == []
    assert api.me(s)["is_instructor"] is False
