"""기수에 시나리오 열기 → 학생이 열린 것만 보고, 상세에는 에이전트에 넘길 검사 정의 전문이 실린다."""

import pytest


def _cohort_with_student(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    return teacher, cohort, student


@pytest.mark.django_db
def test_instructor_sees_the_whole_catalog(api):
    teacher = api.login_instructor()
    res = api.get("/api/instructor/scenarios", teacher)
    assert res.status_code == 200
    ids = [s["id"] for s in res.json()]
    assert "s3-static-site" in ids
    s3 = next(s for s in res.json() if s["id"] == "s3-static-site")
    assert s3 == {
        "id": "s3-static-site",
        "title": "S3 정적 사이트",
        "requires": {"floci": True, "kind": None},
        "total": 4,
    }
    student = api.login("s1")
    assert api.get("/api/instructor/scenarios", student).status_code == 403


@pytest.mark.django_db
def test_opening_scenarios_shows_only_those_to_students(api):
    teacher, cohort, student = _cohort_with_student(api)
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json() == []

    assert api.open_scenarios(teacher, cohort["id"], ["s3-static-site"]) == ["s3-static-site"]
    assert api.get(f"/api/instructor/cohorts/{cohort['id']}", teacher).json()["open_scenario_ids"] == ["s3-static-site"]

    listed = api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()
    assert [(s["id"], s["title"], s["total"], s["passed"]) for s in listed] == [("s3-static-site", "S3 정적 사이트", 4, None)]

    assert api.open_scenarios(teacher, cohort["id"], []) == []
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json() == []


@pytest.mark.django_db
def test_unknown_scenario_id_is_rejected_and_duplicates_collapse(api):
    teacher, cohort, _ = _cohort_with_student(api)
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/scenarios", {"scenario_ids": ["nope"]}, teacher)
    assert res.status_code == 422
    assert "nope" in res.json()["detail"]
    assert api.open_scenarios(teacher, cohort["id"], ["s3-static-site", "s3-static-site"]) == ["s3-static-site"]


@pytest.mark.django_db
def test_scenario_ids_gone_from_the_repo_disappear_for_instructor_and_student_alike(api):
    from cohorts.models import Cohort

    teacher, cohort, student = _cohort_with_student(api)
    api.open_scenarios(teacher, cohort["id"], ["s3-static-site"])
    # 저장소에서 디렉터리가 지워진 뒤의 DB 상태를 흉내 낸다 — API 로는 만들 수 없는 상태다.
    Cohort.objects.filter(pk=cohort["id"]).update(open_scenario_ids=["gone-lab", "s3-static-site"])

    assert api.get(f"/api/instructor/cohorts/{cohort['id']}", teacher).json()["open_scenario_ids"] == ["s3-static-site"]
    assert [s["id"] for s in api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()] == ["s3-static-site"]
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/gone-lab", student).status_code == 404


@pytest.mark.django_db
def test_scenario_detail_carries_the_full_check_definitions_for_the_agent(api):
    teacher, cohort, student = _cohort_with_student(api)
    api.open_scenarios(teacher, cohort["id"], ["s3-static-site"])

    res = api.get(f"/api/cohorts/{cohort['id']}/scenarios/s3-static-site", student)
    assert res.status_code == 200
    d = res.json()
    assert d["title"] == "S3 정적 사이트" and "lab-site" in d["description"]
    assert d["requires"] == {"floci": True, "kind": None}
    assert [c["id"] for c in d["checks"]] == ["bucket-exists", "versioning-enabled", "index-uploaded", "website-configured"]
    first = d["checks"][0]
    assert set(first) == {"id", "name", "hint", "command", "timeout_seconds", "expect", "constraint"}
    assert first["command"] == "aws s3api head-bucket --bucket lab-site"
    assert first["expect"] == {"type": "exit_zero"}
    assert d["checks"][1]["expect"] == {"type": "equals", "value": "Enabled"}
    assert d["scripts"] == {}


@pytest.mark.django_db
def test_closed_or_unknown_scenario_and_outsiders_get_404(api):
    teacher, cohort, student = _cohort_with_student(api)
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/s3-static-site", student).status_code == 404
    api.open_scenarios(teacher, cohort["id"], ["s3-static-site"])
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/nope", student).status_code == 404
    outsider = api.login("out")
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios", outsider).status_code == 404
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/s3-static-site", outsider).status_code == 404
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios").status_code == 401
    assert api.put(f"/api/instructor/cohorts/{cohort['id']}/scenarios", {"scenario_ids": []}, student).status_code == 403
