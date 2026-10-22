"""기수 관리 — 가입 링크 재발급·가입 닫기·학생 내보내기·보관."""

import pytest


@pytest.mark.django_db
def test_regenerated_join_link_kills_the_old_one(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    old = cohort["join_token"]

    res = api.post(f"/api/instructor/cohorts/{cohort['id']}/join-token/regenerate", session=teacher)
    assert res.status_code == 200
    new = res.json()["join_token"]
    assert new != old

    student = api.login("s1")
    assert api.get(f"/api/join/{old}").status_code == 404
    assert api.post(f"/api/join/{old}", session=student).status_code == 404
    assert api.join(student, new)["created"] is True


@pytest.mark.django_db
def test_closed_cohort_refuses_new_students_but_keeps_existing_ones(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    early = api.login("early")
    api.join(early, cohort["join_token"])

    res = api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"join_open": False}, teacher)
    assert res.status_code == 200 and res.json()["join_open"] is False

    late = api.login("late")
    assert api.get(f"/api/join/{cohort['join_token']}").json()["join_open"] is False
    assert api.post(f"/api/join/{cohort['join_token']}", session=late).status_code == 403
    # 이미 들어온 사람은 그대로이고, 링크를 다시 열어도 멱등이다.
    assert [c["id"] for c in api.get("/api/cohorts", early).json()] == [cohort["id"]]
    assert api.join(early, cohort["join_token"])["created"] is False

    api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"join_open": True}, teacher)
    assert api.join(late, cohort["join_token"])["created"] is True


@pytest.mark.django_db
def test_removed_student_disappears_and_loses_the_cohort(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    s1 = api.login("s1", nickname="철수")
    s2 = api.login("s2", nickname="영희")
    api.join(s1, cohort["join_token"])
    api.join(s2, cohort["join_token"])
    people = api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher).json()
    victim = next(p for p in people if p["display_name"] == "철수")

    res = api.delete(f"/api/instructor/cohorts/{cohort['id']}/participants/{victim['membership_id']}", teacher)
    assert res.status_code == 204

    names = [p["display_name"] for p in api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher).json()]
    assert names == ["영희"]
    assert api.get("/api/cohorts", s1).json() == []
    # 다시 지우면 404, 다른 기수의 참여 id 로는 지울 수 없다.
    assert api.delete(f"/api/instructor/cohorts/{cohort['id']}/participants/{victim['membership_id']}", teacher).status_code == 404
    other = api.create_cohort(teacher, "다른 기수")
    survivor = next(p for p in people if p["display_name"] == "영희")
    assert api.delete(f"/api/instructor/cohorts/{other['id']}/participants/{survivor['membership_id']}", teacher).status_code == 404


@pytest.mark.django_db
def test_archived_cohort_sorts_last_and_refuses_joins(api):
    teacher = api.login_instructor()
    old = api.create_cohort(teacher, "1기")
    new = api.create_cohort(teacher, "2기")
    student = api.login("s1")
    api.join(student, old["join_token"])

    res = api.patch(f"/api/instructor/cohorts/{old['id']}", {"archived": True}, teacher)
    assert res.status_code == 200 and res.json()["archived"] is True

    listed = api.get("/api/instructor/cohorts", teacher).json()
    assert [(c["name"], c["archived"]) for c in listed] == [("2기", False), ("1기", True)]

    mine = api.get("/api/cohorts", student).json()
    assert [(c["name"], c["archived"]) for c in mine] == [("1기", True)]

    newcomer = api.login("s2")
    assert api.get(f"/api/join/{old['join_token']}").json()["join_open"] is False
    assert api.post(f"/api/join/{old['join_token']}", session=newcomer).status_code == 403
    assert api.join(newcomer, new["join_token"])["created"] is True

    api.patch(f"/api/instructor/cohorts/{old['id']}", {"archived": False}, teacher)
    assert api.join(newcomer, old["join_token"])["created"] is True


@pytest.mark.django_db
def test_management_is_instructor_only(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    mid = api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher).json()[0]["membership_id"]

    assert api.post(f"/api/instructor/cohorts/{cohort['id']}/join-token/regenerate", session=student).status_code == 403
    assert api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"archived": True}, student).status_code == 403
    assert api.delete(f"/api/instructor/cohorts/{cohort['id']}/participants/{mid}", student).status_code == 403
