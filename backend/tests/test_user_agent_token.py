"""에이전트 토큰은 사용자 하나에 하나(#153) — 수업↔연습을 오가도 compose.yml 을 다시 받지 않는다.

한 사용자의 수업 기수·연습 참여가 같은 토큰·같은 compose 를 쓰고, 그 세션으로 두 묶음 모두 시나리오 준비·채점이 된다.
남의 기수엔 여전히 404. 재발급은 사용자 단위라 모든 묶음의 compose 가 함께 바뀐다. 응시(숨은 사용자)는 따로다.
데이터 이전은 accounts 를 0002 로 되감고 옛 모양의 참여를 만든 뒤 끝까지 돌려 본다(트랜잭션 시험).
"""

from datetime import timedelta

import pytest
import yaml
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.utils import timezone

from tests.api_helpers import S3, Session, s3_results
from tests.test_spec_exam_attempt import _browser, _enter, _setup


def _token(api, session: Session, cohort_id: int) -> str:
    res = api.get(f"/api/cohorts/{cohort_id}", session)
    assert res.status_code == 200, res.content
    return res.json()["agent_token"]


def _compose_token(api, session: Session, cohort_id: int) -> str:
    res = api.get(f"/api/cohorts/{cohort_id}/compose.yml", session)
    assert res.status_code == 200, res.content
    return yaml.safe_load(res.content)["services"]["agent"]["environment"]["AGENT_TOKEN"]


def _class_and_practice(api, uid: str = "s1"):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기")
    api.open_scenarios(teacher, cohort["id"], [S3])
    student = api.login(uid)
    api.join(student, cohort["join_token"])
    res = api.post("/api/practice/join", session=student)
    assert res.status_code == 200, res.content
    return teacher, cohort, student, res.json()["cohort_id"]


@pytest.mark.django_db
def test_class_and_practice_share_one_token_and_one_compose(api):
    _, cohort, student, pid = _class_and_practice(api)

    token = _token(api, student, cohort["id"])
    assert len(token) >= 20
    assert _token(api, student, pid) == token
    assert _compose_token(api, student, cohort["id"]) == token
    assert _compose_token(api, student, pid) == token


@pytest.mark.django_db
def test_one_session_prepares_and_grades_in_both_class_and_practice(api):
    _, cohort, student, pid = _class_and_practice(api)

    for cid in (cohort["id"], pid):
        assert api.get(f"/api/cohorts/{cid}/scenarios/{S3}/prepare", student).status_code == 200
        res = api.submit(student, cid, S3, s3_results({"bucket-exists"}))
        assert res.status_code == 201, res.content
        latest = api.get(f"/api/cohorts/{cid}/scenarios/{S3}/submissions/latest", student).json()
        assert latest["id"] == res.json()["id"]


@pytest.mark.django_db
def test_different_users_get_different_tokens_and_cannot_reach_each_others_cohort(api):
    teacher, cohort, a, _ = _class_and_practice(api, "a")
    other = api.create_cohort(teacher, "2기")
    b = api.login("b")
    api.join(b, other["join_token"])

    assert _token(api, a, cohort["id"]) != _token(api, b, other["id"])
    assert api.get(f"/api/cohorts/{other['id']}", a).status_code == 404
    assert api.get(f"/api/cohorts/{other['id']}/compose.yml", a).status_code == 404
    assert api.get(f"/api/cohorts/{other['id']}/scenarios/{S3}/prepare", a).status_code == 404
    assert api.post(f"/api/cohorts/{other['id']}/agent-token/regenerate", session=a).status_code == 404


@pytest.mark.django_db
def test_regenerating_changes_the_token_of_every_cohort_and_retires_the_old_one(api):
    _, cohort, student, pid = _class_and_practice(api)
    old = _token(api, student, cohort["id"])

    res = api.post(f"/api/cohorts/{pid}/agent-token/regenerate", session=student)
    assert res.status_code == 200, res.content
    new = res.json()["agent_token"]

    assert new != old
    for cid in (cohort["id"], pid):
        assert _token(api, student, cid) == new
        assert _compose_token(api, student, cid) == new


@pytest.mark.django_db
def test_exam_candidate_keeps_a_separate_token_even_in_a_students_browser(api):
    _, cohort, student, _ = _class_and_practice(api)
    student_token = _token(api, student, cohort["id"])

    _, exam, invite = _setup(api)
    cand = _browser()
    _enter(api, cand, invite["token"])
    exam_token = _token(api, cand, exam["id"])

    assert exam_token != student_token
    assert _compose_token(api, cand, exam["id"]) == exam_token
    res = api.get(f"/api/exam/{invite['token']}/compose.yml")
    assert res.status_code == 200
    assert yaml.safe_load(res.content)["services"]["agent"]["environment"]["AGENT_TOKEN"] == exam_token


# ---------- 데이터 이전 ----------


@pytest.mark.django_db(transaction=True)
def test_migration_moves_the_most_recently_used_membership_token_to_the_user():
    executor = MigrationExecutor(connection)
    executor.migrate([("accounts", "0002_sandcorp_auth")])
    executor = MigrationExecutor(connection)
    apps = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
    User = apps.get_model("accounts", "User")
    Organization = apps.get_model("orgs", "Organization")
    Cohort = apps.get_model("cohorts", "Cohort")
    Membership = apps.get_model("cohorts", "Membership")
    Submission = apps.get_model("submissions", "Submission")

    org = Organization.objects.create(name="o")
    c1 = Cohort.objects.create(org=org, name="1기", join_token="j1")
    c2 = Cohort.objects.create(org=org, name="연습", kind="practice", join_token="j2")
    now = timezone.now()

    # 갑: 연습에 나중에 가입했지만 수업 쪽에 더 최근 제출이 있다 → 수업 토큰.
    gap = User.objects.create(username="sandcorp:gap")
    m_class = Membership.objects.create(user=gap, cohort=c1, agent_token="gap-class")
    m_prac = Membership.objects.create(user=gap, cohort=c2, agent_token="gap-practice")
    Membership.objects.filter(pk=m_class.pk).update(joined_at=now - timedelta(days=10))
    Membership.objects.filter(pk=m_prac.pk).update(joined_at=now - timedelta(days=5))
    sub = Submission.objects.create(membership=m_class, scenario_id=S3, passed=0, total=1, results=[])
    Submission.objects.filter(pk=sub.pk).update(submitted_at=now - timedelta(days=1))

    # 을: 제출 없음 → 가장 늦게 가입한 참여의 토큰.
    eul = User.objects.create(username="sandcorp:eul")
    m1 = Membership.objects.create(user=eul, cohort=c1, agent_token="eul-class")
    m2 = Membership.objects.create(user=eul, cohort=c2, agent_token="eul-practice")
    Membership.objects.filter(pk=m1.pk).update(joined_at=now - timedelta(days=3))
    Membership.objects.filter(pk=m2.pk).update(joined_at=now - timedelta(days=2))

    # 병: 참여 없음 → 이전은 비워 두고 처음 필요할 때 만든다.
    User.objects.create(username="sandcorp:byeong")

    executor = MigrationExecutor(connection)
    executor.migrate(executor.loader.graph.leaf_nodes())

    from accounts.models import User as NewUser
    from accounts.models import agent_token_for

    assert NewUser.objects.get(username="sandcorp:gap").agent_token == "gap-class"
    assert NewUser.objects.get(username="sandcorp:eul").agent_token == "eul-practice"
    byeong = NewUser.objects.get(username="sandcorp:byeong")
    assert byeong.agent_token is None
    assert len(agent_token_for(byeong)) >= 20
    assert NewUser.objects.get(pk=byeong.pk).agent_token == byeong.agent_token
