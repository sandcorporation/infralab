"""내 기록 — 시나리오별 최고 점수·제출 수·마지막 제출 시각, 제출 이력, 제출 하나의 검사 결과와 피드백.

target: backend/tests/test_spec_practice_record.py
AC: #136: GET /api/practice/scenarios 가 모든 시나리오를 best_passed(없으면 null)·total·submission_count·last_submitted_at 와 함께 준다. 최고 점수는 지금 검사 정의로 다시 센 통과 수 중 가장 큰 것. 참여 전 404
AC: #136: GET /api/practice/scenarios/<id>/submissions 가 내 제출 이력을 최신부터 {id, submitted_at, passed, total, has_transcript, has_feedback} 로 준다. 없는 시나리오 404
AC: #136: GET /api/practice/submissions/<id> 가 검사별 결과와 피드백(없으면 null)을 준다. 남의 제출·연습이 아닌 묶음의 제출 404
AC: #136: 다른 연습 사용자의 제출은 내 최고 점수·제출 수·이력에 섞이지 않는다

연습 참여(#132)·기존 제출 경로·「피드백 받기」(#134, 가짜 채점기)를 거쳐 기록 API 를 HTTP 로 본다.
"""

import pytest
from django.test import override_settings

from scenarios import registry
from submissions.models import Submission
from tests.api_helpers import S3, S3_CHECK_IDS, s3_results

pytestmark = [pytest.mark.django_db, pytest.mark.usefixtures("fake_grader")]

TRANSCRIPT = [
    {
        "tool": "claude",
        "since": "2026-11-18T01:00:00Z",
        "truncated": False,
        "entries": [
            {"role": "user", "at": "2026-11-18T01:00:01Z", "text": "먼저 버킷을 만들고 그다음 확인해 줘."},
            {"role": "assistant", "at": "2026-11-18T01:00:05Z", "text": "만들었습니다. head-bucket 으로 확인했습니다."},
        ],
    }
]


@pytest.fixture
def fake_grader():
    with override_settings(GRADER_ANTHROPIC_KEY=""):
        yield


def _practice_user(api, uid="p1"):
    s = api.login(uid)
    res = api.post("/api/practice/join", session=s)
    assert res.status_code == 200, res.content
    return s, res.json()["cohort_id"]


def _submit(api, s, cohort_id, passing, transcript=None):
    body = {"agent_version": "0.9.0", "results": s3_results(passing)}
    if transcript is not None:
        body["ai_transcript"] = transcript
    res = api.post(f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions", body, s)
    assert res.status_code == 201, res.content
    return res.json()


def _rows(api, s):
    res = api.get("/api/practice/scenarios", s)
    assert res.status_code == 200, res.content
    return {r["id"]: r for r in res.json()}


def test_scenario_list_has_every_scenario_with_no_record_yet(api):
    s, _ = _practice_user(api)

    res = api.get("/api/practice/scenarios", s)

    assert res.status_code == 200, res.content
    rows = res.json()
    assert [r["id"] for r in rows] == list(registry.all_scenarios())
    for r in rows:
        scenario = registry.get(r["id"])
        assert r["title"] == scenario.title
        assert r["total"] == len(scenario.checks)
        assert (r["best_passed"], r["submission_count"], r["last_submitted_at"]) == (None, 0, None)


def test_scenario_list_shows_best_score_count_and_last_time(api):
    s, pid = _practice_user(api)
    _submit(api, s, pid, {"bucket-exists"})
    _submit(api, s, pid, {"bucket-exists", "versioning-enabled", "index-uploaded"})
    last = _submit(api, s, pid, {"bucket-exists", "versioning-enabled"})

    row = _rows(api, s)[S3]

    assert (row["best_passed"], row["total"], row["submission_count"]) == (3, 4, 3)
    assert row["last_submitted_at"] == last["submitted_at"]


def test_best_score_is_recounted_against_the_current_checks(api):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid, set(S3_CHECK_IDS))
    # 저장된 결과에 지금 시나리오에 없는 검사의 통과가 섞여 있으면 세지 않는다 — 격자·이력과 같은 다시 세기.
    stored = Submission.objects.get(pk=sub["id"])
    stored.results = [*stored.results[:2], *[{**r, "check_id": f"gone-{r['check_id']}"} for r in stored.results[2:]]]
    stored.save(update_fields=["results"])

    assert _rows(api, s)[S3]["best_passed"] == 2


def test_scenario_list_needs_joining(api):
    s = api.login("stranger")

    assert api.get("/api/practice/scenarios", s).status_code == 404
    assert api.get("/api/practice/scenarios").status_code == 401


def test_history_lists_my_submissions_newest_first_with_feedback_flags(api):
    s, pid = _practice_user(api)
    first = _submit(api, s, pid, {"bucket-exists"}, TRANSCRIPT)
    second = _submit(api, s, pid, {"bucket-exists", "versioning-enabled"})
    third = _submit(api, s, pid, set(S3_CHECK_IDS), TRANSCRIPT)
    assert api.post(f"/api/practice/submissions/{first['id']}/feedback", session=s).status_code == 200

    res = api.get(f"/api/practice/scenarios/{S3}/submissions", s)

    assert res.status_code == 200, res.content
    assert [
        (h["id"], h["submitted_at"], h["passed"], h["total"], h["has_transcript"], h["has_feedback"]) for h in res.json()
    ] == [
        (third["id"], third["submitted_at"], 4, 4, True, False),
        (second["id"], second["submitted_at"], 2, 4, False, False),
        (first["id"], first["submitted_at"], 1, 4, True, True),
    ]


def test_history_of_an_unknown_scenario_is_404(api):
    s, _ = _practice_user(api)

    assert api.get("/api/practice/scenarios/no-such-scenario/submissions", s).status_code == 404


def test_submission_detail_has_check_results_and_feedback(api):
    s, pid = _practice_user(api)
    sub = _submit(api, s, pid, {"bucket-exists"}, TRANSCRIPT)

    before = api.get(f"/api/practice/submissions/{sub['id']}", s)
    assert before.status_code == 200, before.content
    body = before.json()
    assert (body["id"], body["scenario_id"], body["passed"], body["total"]) == (sub["id"], S3, 1, 4)
    assert body["has_transcript"] is True
    assert [(r["check_id"], r["pass"]) for r in body["results"]] == [(cid, cid == "bucket-exists") for cid in S3_CHECK_IDS]
    assert body["feedback"] is None

    feedback = api.post(f"/api/practice/submissions/{sub['id']}/feedback", session=s).json()
    after = api.get(f"/api/practice/submissions/{sub['id']}", s).json()
    assert after["feedback"] == feedback
    assert [i["key"] for i in after["feedback"]["items"]] == [
        "decomposition",
        "instruction_clarity",
        "verification",
        "risky_command_guard",
    ]


def test_other_practice_users_records_do_not_mix(api):
    a, pid = _practice_user(api, "pa")
    b, _ = _practice_user(api, "pb")
    sub = _submit(api, a, pid, set(S3_CHECK_IDS), TRANSCRIPT)
    _submit(api, b, pid, {"bucket-exists"})

    row_b = _rows(api, b)[S3]
    assert (row_b["best_passed"], row_b["submission_count"]) == (1, 1)
    assert [h["passed"] for h in api.get(f"/api/practice/scenarios/{S3}/submissions", b).json()] == [1]
    assert api.get(f"/api/practice/submissions/{sub['id']}", b).status_code == 404
    assert _rows(api, a)[S3]["best_passed"] == 4


def test_class_cohort_submission_is_not_a_practice_record(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기")
    api.open_scenarios(teacher, cohort["id"], [S3])
    s, _ = _practice_user(api)
    api.join(s, cohort["join_token"])
    res = api.post(
        f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions",
        {"agent_version": "0.9.0", "results": s3_results(set(S3_CHECK_IDS))},
        s,
    )
    assert res.status_code == 201, res.content

    assert api.get(f"/api/practice/submissions/{res.json()['id']}", s).status_code == 404
    row = _rows(api, s)[S3]
    assert (row["best_passed"], row["submission_count"]) == (None, 0)
    assert api.get(f"/api/practice/scenarios/{S3}/submissions", s).json() == []
