"""시험 대시보드 — 내 조직의 시험 회차별 초대·시작·완료 수와 최종 점수 분포.

target: backend/tests/test_spec_exam_dashboard.py
AC: #77: GET /api/instructor/exam-dashboard 가 내 조직들의 시험 회차만(수업 묶음·남의 조직 제외) 준다
AC: #77: 각 회차의 invited(회수 제외 응시 링크 수)·started(시작한 수)·finished(끝난 수)가 맞다
AC: #77: score_buckets 는 길이 5 이고 끝난 응시의 최종 점수를 구간대로 센다

숨은 검사를 끈 회차(최종 점수 = 공개 검사만)에서 지원자 몇이 서로 다른 수로 통과하고 마친 뒤 담당자가
대시보드를 부른다. 구간은 0–19·20–39·40–59·60–79·80–100. 막대 높이(웹)는
web/src/spec/spec_exam_dashboard.test.ts 가 본다.
"""

import pytest
from django.test import Client

from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

pytestmark = pytest.mark.django_db

EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": [],
    "models": {},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 0,
}


def _exam(api, teacher, name):
    res = api.post("/api/instructor/cohorts", {"name": name, "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    cohort = res.json()
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", EXAM_SETTINGS, teacher)
    assert res.status_code == 200, res.content
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort


def _invite(api, teacher, cohort_id, label):
    res = api.post(f"/api/instructor/cohorts/{cohort_id}/exam-invites", {"label": label}, teacher)
    assert res.status_code == 201, res.content
    return res.json()


def _attempt(api, teacher, cohort_id, label, passing=None, finish=True):
    """응시 하나를 시작하고, `passing` 이 있으면 그만큼 통과한 제출을 내고, `finish` 면 마친다."""

    invite = _invite(api, teacher, cohort_id, label)
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 200
    if passing is not None:
        assert api.submit(cand, cohort_id, S3, s3_results(set(S3_CHECK_IDS[:passing]))).status_code == 201
    if finish:
        assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200
    return invite


@pytest.mark.skip(reason="#77")
def test_dashboard_lists_only_my_orgs_exam_cohorts(api):
    teacher = api.login_instructor()
    mine = _exam(api, teacher, "백엔드 1회차")
    api.create_cohort(teacher, "수업 1기")
    outsider = api.login_instructor("other-owner", org="다른 회사")
    theirs = _exam(api, outsider, "남의 회차")

    res = api.get("/api/instructor/exam-dashboard", teacher)

    assert res.status_code == 200, res.content
    rows = res.json()
    assert [(r["cohort_id"], r["org_id"], r["name"]) for r in rows] == [(mine["id"], mine["org_id"], "백엔드 1회차")]
    assert rows[0] == {
        "cohort_id": mine["id"],
        "org_id": mine["org_id"],
        "name": "백엔드 1회차",
        "invited": 0,
        "started": 0,
        "finished": 0,
        "score_buckets": [0, 0, 0, 0, 0],
    }
    assert [r["cohort_id"] for r in api.get("/api/instructor/exam-dashboard", outsider).json()] == [theirs["id"]]


@pytest.mark.skip(reason="#77")
def test_dashboard_counts_attempts_and_buckets_final_scores(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher, "백엔드 1회차")
    revoked = _invite(api, teacher, cohort["id"], "회수됨")
    assert api.delete(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{revoked['id']}", teacher).status_code == 204
    _invite(api, teacher, cohort["id"], "초대만")
    _attempt(api, teacher, cohort["id"], "응시 중", passing=4, finish=False)
    _attempt(api, teacher, cohort["id"], "만점", passing=4)  # 100 → 80–100
    _attempt(api, teacher, cohort["id"], "넷 중 셋", passing=3)  # 75 → 60–79
    _attempt(api, teacher, cohort["id"], "넷 중 하나", passing=1)  # 25 → 20–39
    _attempt(api, teacher, cohort["id"], "제출 없음")  # 0 → 0–19

    rows = api.get("/api/instructor/exam-dashboard", teacher).json()

    assert len(rows) == 1
    row = rows[0]
    assert row["invited"] == 6  # 회수한 링크는 세지 않는다
    assert row["started"] == 5  # 응시 중 + 끝난 넷
    assert row["finished"] == 4
    assert row["score_buckets"] == [1, 1, 0, 1, 1]
