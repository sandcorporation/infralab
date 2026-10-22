"""기수 만들기 → 가입 링크 → 학생 가입 → 내 기수·참여자 명단."""

import pytest


@pytest.mark.django_db
def test_instructor_creates_a_cohort_and_gets_a_join_token(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "인프라 1기")
    assert cohort["name"] == "인프라 1기"
    assert len(cohort["join_token"]) >= 20
    assert cohort["join_open"] is True and cohort["archived"] is False
    assert cohort["member_count"] == 0 and cohort["open_scenario_ids"] == []

    listed = api.get("/api/instructor/cohorts", teacher).json()
    assert [c["id"] for c in listed] == [cohort["id"]]


@pytest.mark.django_db
def test_students_cannot_create_or_list_cohorts(api):
    student = api.login("s1")
    assert api.post("/api/instructor/cohorts", {"name": "x"}, student).status_code == 403
    assert api.get("/api/instructor/cohorts", student).status_code == 403
    assert api.post("/api/instructor/cohorts", {"name": "x"}).status_code == 401


@pytest.mark.django_db
def test_join_preview_is_public_and_shows_the_cohort_name(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "미리보기 기수")
    res = api.get(f"/api/join/{cohort['join_token']}")
    assert res.status_code == 200
    assert res.json() == {"cohort_id": cohort["id"], "name": "미리보기 기수", "join_open": True}


@pytest.mark.django_db
def test_unknown_join_token_is_404(api):
    assert api.get("/api/join/nope").status_code == 404
    student = api.login("s1")
    assert api.post("/api/join/nope", session=student).status_code == 404


@pytest.mark.django_db
def test_join_requires_login(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    assert api.post(f"/api/join/{cohort['join_token']}").status_code == 401


@pytest.mark.django_db
def test_student_joins_and_sees_the_cohort_in_my_cohorts(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기")
    student = api.login("s1", nickname="철수")

    joined = api.join(student, cohort["join_token"])
    assert joined == {"cohort_id": cohort["id"], "name": "1기", "created": True}

    mine = api.get("/api/cohorts", student).json()
    assert [(c["id"], c["name"], c["archived"]) for c in mine] == [(cohort["id"], "1기", False)]
    assert mine[0]["joined_at"]


@pytest.mark.django_db
def test_joining_twice_keeps_a_single_membership(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    assert api.join(student, cohort["join_token"])["created"] is True
    assert api.join(student, cohort["join_token"])["created"] is False
    assert len(api.get("/api/cohorts", student).json()) == 1
    assert api.get(f"/api/instructor/cohorts/{cohort['id']}", teacher).json()["member_count"] == 1


@pytest.mark.django_db
def test_a_student_can_be_in_several_cohorts(api):
    teacher = api.login_instructor()
    first = api.create_cohort(teacher, "1기")
    second = api.create_cohort(teacher, "2기")
    student = api.login("s1")
    api.join(student, first["join_token"])
    api.join(student, second["join_token"])
    assert sorted(c["name"] for c in api.get("/api/cohorts", student).json()) == ["1기", "2기"]


@pytest.mark.django_db
def test_participants_show_name_and_join_time_and_are_instructor_only(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    a = api.login("s1", nickname="철수")
    b = api.login("s2", nickname="영희")
    api.join(a, cohort["join_token"])
    api.join(b, cohort["join_token"])

    res = api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", teacher)
    assert res.status_code == 200
    people = res.json()
    assert [p["display_name"] for p in people] == ["철수", "영희"]
    assert all(p["joined_at"] and p["username"].startswith("kakao:") for p in people)

    assert api.get(f"/api/instructor/cohorts/{cohort['id']}/participants", a).status_code == 403


@pytest.mark.django_db
def test_instructor_renames_a_cohort(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "임시")
    res = api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"name": "인프라 3기"}, teacher)
    assert res.status_code == 200 and res.json()["name"] == "인프라 3기"
    assert api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"name": ""}, teacher).status_code == 422
    assert api.patch(f"/api/instructor/cohorts/{cohort['id']}", {"name": "   "}, teacher).status_code == 422
    assert api.post("/api/instructor/cohorts", {"name": "  \t "}, teacher).status_code == 422
    # 양끝 공백은 잘려 저장된다
    created = api.create_cohort(teacher, "  4기  ")
    assert created["name"] == "4기"


@pytest.mark.django_db
def test_my_cohorts_is_empty_for_a_fresh_student(api):
    student = api.login("fresh")
    assert api.get("/api/cohorts", student).json() == []
    assert api.get("/api/cohorts").status_code == 401
