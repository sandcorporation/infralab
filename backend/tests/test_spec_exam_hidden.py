"""숨은 검사 최종 채점 — 마감 뒤 한 번만 오가는 숨은 검사 정의·결과, 응시 중 새지 않음, 공개/숨은 점수.

target: backend/tests/test_spec_exam_hidden.py
AC: #74: 응시 중 final-checks 409, 마감 뒤에는 열린 시나리오별 숨은 검사 정의(공개 검사는 없음)
AC: #74: 응시 중 지원자가 받는 어떤 응답(응시 상태, 시나리오 목록·상세·환경 준비, 제출 응답·이력)에도 숨은 검사 id 가 없다
AC: #74: 마감 뒤 final-results 한 번(204), 두 번째 409, 마감 전 409, 숨은 검사 id 가 맞지 않으면 422
AC: #74: 담당자 score 가 공개·숨은 통과/전체, hidden_status(done·pending·skipped), final_percent 를 준다(pending 이면 null). 남의 조직 404
AC: #74: hidden_checks: false 면 final-checks 가 빈 목록이고 점수는 skipped, 공개만으로 final_percent

문제은행은 시험마다 임시 폴더(s3-static-site 의 숨은 검사 둘)로 만들어 레지스트리를 다시 읽는다. 지원자는
로그인 없는 새 테스트 클라이언트가 응시 링크로 들어온다. 점수 공식은
round(100 × (공개 통과 + 숨은 통과) / (공개 전체 + 숨은 전체)).
"""

import pytest
from django.test import Client, override_settings

from scenarios import registry
from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

pytestmark = pytest.mark.django_db

HIDDEN_IDS = ["hidden-index-body", "hidden-website-suffix"]
HIDDEN_YAML = """\
checks:
  - id: hidden-index-body
    name: index.html 본문
    command: aws s3 cp s3://lab-site/index.html - | grep -qi html
    expect: exit_zero
  - id: hidden-website-suffix
    name: 웹사이트 인덱스 문서
    command: aws s3api get-bucket-website --bucket lab-site --query IndexDocument.Suffix --output text
    expect: {equals: index.html}
"""

EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": [],
    "models": {},
    "proctoring": False,
    "hidden_checks": True,
    "ai_token_limit": 0,
}


@pytest.fixture
def hidden_bank(tmp_path):
    root = tmp_path / "problems"
    (root / S3).mkdir(parents=True)
    (root / S3 / "hidden.yaml").write_text(HIDDEN_YAML, encoding="utf-8")
    with override_settings(PROBLEMS_DIR=str(root)):
        registry.load()
        yield root
    registry.load()


@pytest.fixture
def no_bank():
    with override_settings(PROBLEMS_DIR=""):
        registry.load()
        yield
    registry.load()


def _exam(api, teacher, settings=EXAM_SETTINGS):
    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    cohort = res.json()
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", settings, teacher)
    assert res.status_code == 200, res.content
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort


def _attempt(api, teacher, cohort_id, label="지원자 A"):
    res = api.post(f"/api/instructor/cohorts/{cohort_id}/exam-invites", {"label": label}, teacher)
    assert res.status_code == 201, res.content
    invite = res.json()
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    res = api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand)
    assert res.status_code == 200, res.content
    return invite, cand


def _finish(api, cand, token):
    res = api.post(f"/api/exam/{token}/finish", session=cand)
    assert res.status_code == 200, res.content


def _hidden_results(passing: set[str], ids=HIDDEN_IDS):
    return [
        {"id": cid, "name": cid, "pass": cid in passing, "output": "ok" if cid in passing else "no", "exit_code": 0 if cid in passing else 1}
        for cid in ids
    ]


def _final_results(api, cand, token, results):
    body = {"agent_version": "0.4.0", "scenarios": [{"scenario_id": S3, "results": results}]}
    return api.post(f"/api/exam/{token}/final-results", body, cand)


def _score(api, teacher, cohort_id, invite_id):
    return api.get(f"/api/instructor/cohorts/{cohort_id}/exam-invites/{invite_id}/score", teacher)


@pytest.mark.skip(reason="#74")
def test_final_checks_are_409_during_the_attempt_and_hidden_only_after_it(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])

    assert api.get(f"/api/exam/{invite['token']}/final-checks", cand).status_code == 409

    _finish(api, cand, invite["token"])
    res = api.get(f"/api/exam/{invite['token']}/final-checks", cand)

    assert res.status_code == 200, res.content
    scenarios = res.json()["scenarios"]
    assert [s["scenario_id"] for s in scenarios] == [S3]
    assert [c["id"] for c in scenarios[0]["checks"]] == HIDDEN_IDS
    assert scenarios[0]["checks"][1]["expect"] == {"type": "equals", "value": "index.html"}
    assert isinstance(scenarios[0]["scripts"], dict)
    assert not any(cid in res.content.decode() for cid in S3_CHECK_IDS)


@pytest.mark.skip(reason="#74")
def test_no_candidate_response_leaks_hidden_checks_during_the_attempt(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])
    base = f"/api/cohorts/{cohort['id']}/scenarios"

    submitted = api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS)))
    assert submitted.status_code == 201, submitted.content
    responses = [
        api.get(f"/api/exam/{invite['token']}", cand),
        api.get(base, cand),
        api.get(f"{base}/{S3}", cand),
        api.get(f"{base}/{S3}/prepare", cand),
        submitted,
        api.get(f"{base}/{S3}/submissions", cand),
        api.get(f"{base}/{S3}/submissions/latest", cand),
    ]

    for res in responses:
        assert res.status_code in (200, 201), (res.status_code, res.content)
        body = res.content.decode()
        for hidden_id in HIDDEN_IDS:
            assert hidden_id not in body
        assert "index.html 본문" not in body


@pytest.mark.skip(reason="#74")
def test_final_results_are_taken_once_after_the_end(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])

    assert _final_results(api, cand, invite["token"], _hidden_results(set(HIDDEN_IDS))).status_code == 409

    _finish(api, cand, invite["token"])
    assert _final_results(api, cand, invite["token"], _hidden_results(set(), ids=["hidden-index-body"])).status_code == 422
    assert _final_results(api, cand, invite["token"], _hidden_results(set(), ids=[*HIDDEN_IDS, "bucket-exists"])).status_code == 422
    assert _final_results(api, cand, invite["token"], _hidden_results(set(), ids=S3_CHECK_IDS)).status_code == 422

    first = _final_results(api, cand, invite["token"], _hidden_results({"hidden-index-body"}))
    assert first.status_code == 204
    assert first.content == b""
    second = _final_results(api, cand, invite["token"], _hidden_results(set(HIDDEN_IDS)))
    assert second.status_code == 409
    # 두 번째 결과는 점수를 바꾸지 않는다.
    assert _score(api, teacher, cohort["id"], invite["id"]).json()["hidden_passed"] == 1


@pytest.mark.skip(reason="#74")
def test_score_combines_public_and_hidden_checks(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])
    # 공개: 옛 제출 1/4 뒤 최신 제출 3/4 — 최신 것을 센다.
    api.submit(cand, cohort["id"], S3, s3_results({"bucket-exists"}))
    api.submit(cand, cohort["id"], S3, s3_results({"bucket-exists", "versioning-enabled", "index-uploaded"}))
    _finish(api, cand, invite["token"])

    pending = _score(api, teacher, cohort["id"], invite["id"])
    assert pending.status_code == 200, pending.content
    assert pending.json()["hidden_status"] == "pending"
    assert (pending.json()["public_passed"], pending.json()["public_total"]) == (3, 4)
    # 숨은 결과를 기다리는 동안 최종 점수는 없다(공개만으로 낸 점수를 최종으로 보이지 않는다).
    assert pending.json()["final_percent"] is None

    assert _final_results(api, cand, invite["token"], _hidden_results({"hidden-website-suffix"})).status_code == 204
    score = _score(api, teacher, cohort["id"], invite["id"]).json()

    assert score == {
        "public_passed": 3,
        "public_total": 4,
        "hidden_passed": 1,
        "hidden_total": 2,
        "hidden_status": "done",
        "final_percent": round(100 * (3 + 1) / (4 + 2)),
    }


@pytest.mark.skip(reason="#74")
def test_score_without_a_submission_counts_zero_public_passes(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])
    _finish(api, cand, invite["token"])
    _final_results(api, cand, invite["token"], _hidden_results(set(HIDDEN_IDS)))

    score = _score(api, teacher, cohort["id"], invite["id"]).json()

    assert (score["public_passed"], score["public_total"]) == (0, 4)
    assert (score["hidden_passed"], score["hidden_total"]) == (2, 2)
    assert score["final_percent"] == round(100 * 2 / 6)


@pytest.mark.skip(reason="#74")
def test_score_of_another_orgs_invite_is_404(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert _score(api, outsider, cohort["id"], invite["id"]).status_code == 404
    other = _exam(api, teacher)
    assert _score(api, teacher, other["id"], invite["id"]).status_code == 404


@pytest.mark.skip(reason="#74")
def test_hidden_checks_off_skips_them_and_scores_public_only(api, hidden_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher, {**EXAM_SETTINGS, "hidden_checks": False})
    invite, cand = _attempt(api, teacher, cohort["id"])
    api.submit(cand, cohort["id"], S3, s3_results({"bucket-exists", "versioning-enabled", "index-uploaded"}))
    _finish(api, cand, invite["token"])

    res = api.get(f"/api/exam/{invite['token']}/final-checks", cand)
    assert res.status_code == 200, res.content
    assert res.json() == {"scenarios": []}

    score = _score(api, teacher, cohort["id"], invite["id"]).json()
    assert score["hidden_status"] == "skipped"
    assert (score["hidden_passed"], score["hidden_total"]) == (0, 0)
    assert score["final_percent"] == 75


@pytest.mark.skip(reason="#74")
def test_hidden_checks_are_skipped_when_the_problem_bank_has_none(api, no_bank):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])
    api.submit(cand, cohort["id"], S3, s3_results(set(S3_CHECK_IDS)))
    _finish(api, cand, invite["token"])

    assert api.get(f"/api/exam/{invite['token']}/final-checks", cand).json() == {"scenarios": []}
    score = _score(api, teacher, cohort["id"], invite["id"]).json()
    assert score["hidden_status"] == "skipped"
    assert score["final_percent"] == 100
