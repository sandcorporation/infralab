"""제출 — 에이전트 결과가 이력으로 쌓이고, 목록의 통과 수는 최신 것을 따른다."""

import pytest

from tests.api_helpers import S3, S3_CHECK_IDS as CHECK_IDS, s3_results as _results







def _setup(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], [S3])
    return teacher, cohort, student


def _submit(api, student, cohort_id, results, agent_version="0.2.0"):
    return api.post(
        f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions",
        {"agent_version": agent_version, "results": results},
        student,
    )


@pytest.mark.django_db
def test_submission_is_stored_with_evidence_and_the_list_shows_the_latest_score(api):
    _, cohort, student = _setup(api)
    res = _submit(api, student, cohort["id"], _results({"bucket-exists"}))
    assert res.status_code == 201, res.content
    sub = res.json()
    assert (sub["passed"], sub["total"], sub["agent_version"]) == (1, 4, "0.2.0")
    assert [r["check_id"] for r in sub["results"]] == CHECK_IDS
    assert sub["results"][0]["pass"] is True and sub["results"][1]["pass"] is False
    assert sub["results"][1]["output"] == "An error occurred (404)" and sub["results"][1]["exit_code"] == 254
    assert sub["results"][0]["name"] == "버킷 lab-site 존재"  # 이름은 시나리오 정의에서 온다

    listed = api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()
    assert (listed[0]["passed"], listed[0]["total"]) == (1, 4)

    _submit(api, student, cohort["id"], _results(set(CHECK_IDS)))
    listed = api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()
    assert (listed[0]["passed"], listed[0]["total"]) == (4, 4)


@pytest.mark.django_db
def test_history_keeps_every_submission_newest_first(api):
    _, cohort, student = _setup(api)
    _submit(api, student, cohort["id"], _results(set()))
    _submit(api, student, cohort["id"], _results({"bucket-exists", "versioning-enabled"}))
    _submit(api, student, cohort["id"], _results(set(CHECK_IDS)))

    history = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", student).json()
    assert [h["passed"] for h in history] == [4, 2, 0]
    latest = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions/latest", student).json()
    assert latest["passed"] == 4 and len(latest["results"]) == 4


@pytest.mark.django_db
def test_no_submission_yet_is_404_on_latest_and_null_in_the_list(api):
    _, cohort, student = _setup(api)
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions/latest", student).status_code == 404
    assert api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()[0]["passed"] is None


@pytest.mark.django_db
def test_long_agent_version_is_clipped_not_rejected(api):
    _, cohort, student = _setup(api)
    res = _submit(api, student, cohort["id"], _results(set()), agent_version="0.2.0-dirty+" + "f" * 100)
    assert res.status_code == 201
    assert len(res.json()["agent_version"]) == 64


@pytest.mark.django_db
def test_latest_score_is_recounted_against_the_current_checks(api, monkeypatch):
    from scenarios import registry

    _, cohort, student = _setup(api)
    _submit(api, student, cohort["id"], _results(set(CHECK_IDS)))
    # 시나리오 정의에서 검사 하나가 사라진 뒤의 레지스트리를 흉내 낸다.
    s = registry.get(S3)
    trimmed = type(s)(**{**s.__dict__, "checks": s.checks[:3]})
    monkeypatch.setattr(registry, "all_scenarios", lambda: {S3: trimmed})
    monkeypatch.setattr(registry, "get", lambda sid: trimmed if sid == S3 else None)

    listed = api.get(f"/api/cohorts/{cohort['id']}/scenarios", student).json()
    assert (listed[0]["passed"], listed[0]["total"]) == (3, 3)


@pytest.mark.django_db
def test_raw_output_is_clipped_server_side(api):
    _, cohort, student = _setup(api)
    res = _submit(api, student, cohort["id"], _results(set(CHECK_IDS), output="x" * 20000))
    r = res.json()["results"][0]
    assert r["truncated"] is True and len(r["output"]) < 4200 and r["output"].endswith("…(truncated)")


@pytest.mark.django_db
def test_results_must_match_the_scenario_checks(api):
    _, cohort, student = _setup(api)
    missing = _results(set(CHECK_IDS))[:3]
    assert _submit(api, student, cohort["id"], missing).status_code == 422
    foreign = _results(set(CHECK_IDS)) + [{"id": "extra", "pass": True}]
    assert _submit(api, student, cohort["id"], foreign).status_code == 422
    assert _submit(api, student, cohort["id"], "not-a-list").status_code == 422


@pytest.mark.django_db
def test_closed_scenario_or_outsider_cannot_submit(api):
    teacher, cohort, student = _setup(api)
    outsider = api.login("out")
    assert _submit(api, outsider, cohort["id"], _results(set())).status_code == 404
    api.open_scenarios(teacher, cohort["id"], [])
    assert _submit(api, student, cohort["id"], _results(set())).status_code == 404
    assert api.post(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", {"results": []}).status_code == 401
