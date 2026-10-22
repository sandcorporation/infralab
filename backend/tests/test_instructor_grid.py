"""강사 격자 — 참여자 × 시나리오 × 최신 제출, 칸의 이력과 증거."""

import pytest

from tests.api_helpers import S3, S3_CHECK_IDS as CHECK_IDS, s3_results as _results


def _grid(api, teacher, cohort_id):
    res = api.get(f"/api/instructor/cohorts/{cohort_id}/grid", teacher)
    assert res.status_code == 200, res.content
    return res.json()


@pytest.mark.django_db
def test_grid_shows_latest_score_per_student_and_scenario(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    api.open_scenarios(teacher, cohort["id"], [S3])
    a = api.login("a", nickname="철수")
    b = api.login("b", nickname="영희")
    api.join(a, cohort["join_token"])
    api.join(b, cohort["join_token"])
    api.post(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", {"agent_version": "0.4.0", "results": _results(set())}, a)
    api.post(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", {"agent_version": "0.4.0", "results": _results({"bucket-exists", "versioning-enabled", "index-uploaded"})}, a)

    g = _grid(api, teacher, cohort["id"])
    assert g["scenarios"] == [{"id": S3, "title": "S3 정적 사이트", "total": 4}]
    assert [r["display_name"] for r in g["rows"]] == ["철수", "영희"]
    cell_a = g["rows"][0]["cells"][S3]
    assert (cell_a["passed"], cell_a["total"], cell_a["agent_version"]) == (3, 4, "0.4.0")
    assert cell_a["submitted_at"]
    assert g["rows"][1]["cells"][S3] is None


@pytest.mark.django_db
def test_grid_only_has_open_scenarios_and_is_instructor_only(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s")
    api.join(student, cohort["join_token"])
    assert _grid(api, teacher, cohort["id"])["scenarios"] == []
    assert api.get(f"/api/instructor/cohorts/{cohort['id']}/grid", student).status_code == 403
    assert api.get("/api/instructor/cohorts/999/grid", teacher).status_code == 404


@pytest.mark.django_db
def test_history_and_detail_expose_evidence(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    api.open_scenarios(teacher, cohort["id"], [S3])
    student = api.login("s", nickname="철수")
    api.join(student, cohort["join_token"])
    api.post(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", {"results": _results(set())}, student)
    api.post(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", {"results": _results(set(CHECK_IDS), output="all good")}, student)

    g = _grid(api, teacher, cohort["id"])
    row = g["rows"][0]
    history = api.get(
        f"/api/instructor/cohorts/{cohort['id']}/participants/{row['membership_id']}/scenarios/{S3}/submissions", teacher
    ).json()
    assert [h["passed"] for h in history] == [4, 0]
    assert history[0]["id"] == row["cells"][S3]["submission_id"]

    detail = api.get(f"/api/instructor/submissions/{history[0]['id']}", teacher).json()
    assert detail["passed"] == 4 and len(detail["results"]) == 4
    assert detail["results"][0]["output"] == "all good" and detail["results"][0]["check_id"] == "bucket-exists"
    older = api.get(f"/api/instructor/submissions/{history[1]['id']}", teacher).json()
    assert older["results"][0]["pass"] is False and "404" in older["results"][0]["output"]

    assert api.get(f"/api/instructor/submissions/{history[0]['id']}", student).status_code == 403
    other = api.create_cohort(teacher, "다른")
    assert api.get(f"/api/instructor/cohorts/{other['id']}/participants/{row['membership_id']}/scenarios/{S3}/submissions", teacher).status_code == 404
