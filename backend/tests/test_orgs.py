"""조직 → 묶음 → 응시자 — 조직 담당자만 자기 조직의 기수·제출을 본다. 관리 명령, /accounts/me 의 orgs."""

import pytest
from django.core.management import CommandError, call_command

from tests.api_helpers import S3, s3_results


def _two_orgs(api):
    """조직 A·B 담당자와 각자의 기수 하나, B 기수에는 학생 제출 하나."""

    a = api.login_instructor("teacher-a", org="A 학교")
    b = api.login_instructor("teacher-b", org="B 회사")
    cohort_a = api.create_cohort(a, "A 1기")
    cohort_b = api.create_cohort(b, "B 1회차")
    api.open_scenarios(b, cohort_b["id"], [S3])
    student = api.login("student-b")
    api.join(student, cohort_b["join_token"])
    res = api.submit(student, cohort_b["id"], S3, s3_results({"bucket-exists"}))
    assert res.status_code in (200, 201), res.content
    return a, b, cohort_a, cohort_b, res.json()["id"]


@pytest.mark.django_db
def test_org_staff_sees_only_own_org_cohorts(api):
    a, b, cohort_a, cohort_b, _ = _two_orgs(api)

    assert [c["id"] for c in api.get("/api/instructor/cohorts", a).json()] == [cohort_a["id"]]
    assert [c["id"] for c in api.get("/api/instructor/cohorts", b).json()] == [cohort_b["id"]]
    assert cohort_a["org_id"] != cohort_b["org_id"]


@pytest.mark.django_db
def test_org_boundary_blocks_management_grid_detail_and_removal(api):
    a, b, _, cohort_b, submission_id = _two_orgs(api)
    cid = cohort_b["id"]
    participants = api.get(f"/api/instructor/cohorts/{cid}/participants", b).json()
    membership_id = participants[0]["membership_id"]

    denied = [
        api.get(f"/api/instructor/cohorts/{cid}", a),
        api.patch(f"/api/instructor/cohorts/{cid}", {"name": "탈취"}, a),
        api.post(f"/api/instructor/cohorts/{cid}/join-token/regenerate", session=a),
        api.get(f"/api/instructor/cohorts/{cid}/participants", a),
        api.put(f"/api/instructor/cohorts/{cid}/scenarios", {"scenario_ids": []}, a),
        api.get(f"/api/instructor/cohorts/{cid}/grid", a),
        api.get(f"/api/instructor/cohorts/{cid}/participants/{membership_id}/scenarios/{S3}/submissions", a),
        api.get(f"/api/instructor/submissions/{submission_id}", a),
        api.delete(f"/api/instructor/cohorts/{cid}/participants/{membership_id}", a),
    ]
    assert [r.status_code for r in denied] == [404] * len(denied)

    # B 쪽은 아무것도 바뀌지 않았다.
    after = api.get(f"/api/instructor/cohorts/{cid}", b).json()
    assert (after["name"], after["join_token"], after["open_scenario_ids"], after["member_count"]) == (
        "B 1회차",
        cohort_b["join_token"],
        [S3],
        1,
    )
    assert api.get(f"/api/instructor/submissions/{submission_id}", b).status_code == 200


@pytest.mark.django_db
def test_staff_role_can_manage_and_shares_the_org(api):
    owner = api.login_instructor("owner", org="A 학교")
    staff = api.login_instructor("staff", org="A 학교", role="staff")
    cohort = api.create_cohort(staff, "staff 가 만든 기수")

    assert [c["id"] for c in api.get("/api/instructor/cohorts", owner).json()] == [cohort["id"]]
    assert api.me(staff)["orgs"][0]["role"] == "staff"


@pytest.mark.django_db
def test_create_cohort_needs_org_when_staff_of_several(api):
    t = api.login_instructor("multi", org="A 학교")
    api.login_instructor("multi", org="B 회사")
    orgs = {o["name"]: o["id"] for o in api.me(t)["orgs"]}

    assert api.post("/api/instructor/cohorts", {"name": "1기"}, t).status_code == 422
    res = api.post("/api/instructor/cohorts", {"name": "1기", "org_id": orgs["B 회사"]}, t)
    assert res.status_code == 201
    assert res.json()["org_id"] == orgs["B 회사"]

    other = api.login_instructor("other", org="C 학원")
    other_org = api.me(other)["orgs"][0]["id"]
    assert api.post("/api/instructor/cohorts", {"name": "x", "org_id": other_org}, t).status_code == 403


@pytest.mark.django_db
def test_me_lists_orgs_and_is_instructor_follows_them(api):
    s = api.login("someone")
    assert api.me(s)["is_instructor"] is False
    assert api.me(s)["orgs"] == []

    call_command("create_org", "A 학교", "--owner", "sandcorp:someone")
    me = api.me(s)
    assert me["is_instructor"] is True
    assert [(o["name"], o["role"]) for o in me["orgs"]] == [("A 학교", "owner")]
    assert api.get("/api/instructor/me", s).status_code == 200


@pytest.mark.django_db
def test_add_org_member_by_name_or_id_and_role_change(api):
    api.login("boss")
    s = api.login("helper")
    call_command("create_org", "A 학교", "--owner", "sandcorp:boss")
    call_command("add_org_member", "A 학교", "sandcorp:helper", "--role", "staff")
    me = api.me(s)
    assert [(o["name"], o["role"]) for o in me["orgs"]] == [("A 학교", "staff")]

    call_command("add_org_member", str(me["orgs"][0]["id"]), "sandcorp:helper")
    assert api.me(s)["orgs"][0]["role"] == "owner"


@pytest.mark.django_db
def test_org_commands_fail_clearly(api):
    api.login("boss")
    with pytest.raises(CommandError, match="사용자가 없습니다"):
        call_command("create_org", "A 학교", "--owner", "sandcorp:nobody")
    call_command("create_org", "A 학교", "--owner", "sandcorp:boss")
    with pytest.raises(CommandError, match="이미 있습니다"):
        call_command("create_org", "A 학교", "--owner", "sandcorp:boss")
    with pytest.raises(CommandError, match="조직이 없습니다"):
        call_command("add_org_member", "없는 조직", "sandcorp:boss")


@pytest.mark.django_db
def test_cohort_kind_defaults_to_class_and_round_trips(api):
    teacher = api.login_instructor("teacher-k")
    default = api.create_cohort(teacher, "수업 1기")
    assert (default["kind"], default["exam_settings"]) == ("class", {})

    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    exam = res.json()
    assert (exam["kind"], exam["exam_settings"]) == ("exam", {})

    listed = {c["id"]: c["kind"] for c in api.get("/api/instructor/cohorts", teacher).json()}
    assert listed == {default["id"]: "class", exam["id"]: "exam"}
    assert api.get(f"/api/instructor/cohorts/{exam['id']}", teacher).json()["kind"] == "exam"

    bad = api.post("/api/instructor/cohorts", {"name": "x", "kind": "quiz"}, teacher)
    assert bad.status_code == 422


@pytest.mark.django_db
def test_exam_cohort_of_other_org_is_hidden(api):
    a = api.login_instructor("teacher-a2", org="A 학교")
    b = api.login_instructor("teacher-b2", org="B 회사")
    res = api.post("/api/instructor/cohorts", {"name": "B 시험", "kind": "exam"}, b)
    assert api.get("/api/instructor/cohorts", a).json() == []
    assert api.get(f"/api/instructor/cohorts/{res.json()['id']}", a).status_code == 404
