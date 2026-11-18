"""지원자 보고서 — 결과 점수, LLM 루브릭(가짜 채점기), 담당자 수정과 수정 이력.

target: backend/tests/test_spec_exam_report.py
AC: #76: 채점 전 GET report 는 결과 점수와 rubric: null, PATCH 409
AC: #76: grade 뒤 루브릭이 네 항목을 이 순서로 갖고 점수는 0~5 정수, 근거 인용은 모두 그 응시의 프록시 기록 안의 글, 키가 없으면 grader fake
AC: #76: 같은 기록을 두 번 채점하면 같은 점수·근거(가짜 채점기)
AC: #76: PATCH rubric/{key} 로 score 가 바뀌고 llm_score 그대로, edited true, edits 에 {key, from_score, to_score, reason, by, at} 가 쌓인다
AC: #76: 사유가 비었거나 점수가 0~5 밖이면 422, 모르는 항목 404, 남의 조직 404
AC: #76: 다른 응시의 프록시 기록은 이 보고서의 근거로 쓰이지 않는다

응시마다 프록시 기록을 프록시 전용 내부 API(`/api/proxy/exchanges`, #72)로 남기고 응시를 마친 뒤 담당자가
보고서 API 를 부른다. 채점 키(`GRADER_ANTHROPIC_KEY`)는 비워 가짜 채점기만 쓴다 — 시험은 가짜 채점기의 구체
점수가 아니라 모양·범위·근거의 출처·결정성·수정 이력을 본다.
"""

import pytest
from django.test import Client, override_settings

from tests.api_helpers import S3, Session

SECRET = "proxy-secret-for-tests"
RUBRIC_KEYS = ["decomposition", "instruction_clarity", "verification", "risky_command_guard"]
EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["claude_code"],
    "models": {"claude_code": "claude-sonnet-4-5"},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 100000,
}
MINE = [
    (
        "먼저 버킷을 만들고, 그다음 버저닝을 켜고, 마지막으로 index.html 을 올리는 순서로 나눠서 해 줘.",
        "좋습니다. 1단계로 aws s3 mb s3://lab-site 를 실행합니다. 실행 전에 버킷 이름이 맞는지 확인하겠습니다.",
    ),
    (
        "rm -rf 같은 위험한 명령은 쓰지 말고, 끝나면 aws s3api get-bucket-versioning 으로 결과를 검증해 줘.",
        "검증 결과 Status 는 Enabled 입니다. 위험한 삭제 명령은 실행하지 않았습니다.",
    ),
]
THEIRS = [
    ("OTHER-CANDIDATE 의 질문: 쿠버네티스 파드를 다시 띄워 줘.", "OTHER-CANDIDATE 의 답: kubectl rollout restart 를 실행합니다."),
]

pytestmark = [pytest.mark.django_db, pytest.mark.usefixtures("grader_settings")]


@pytest.fixture
def grader_settings():
    with override_settings(EXAM_PROXY_SECRET=SECRET, GRADER_ANTHROPIC_KEY=""):
        yield


def _exam(api, teacher):
    res = api.post("/api/instructor/cohorts", {"name": "1회차", "kind": "exam"}, teacher)
    assert res.status_code == 201, res.content
    cohort = res.json()
    res = api.put(f"/api/instructor/cohorts/{cohort['id']}/exam-settings", EXAM_SETTINGS, teacher)
    assert res.status_code == 200, res.content
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort


def _finished_attempt(api, teacher, cohort_id, label, exchanges):
    res = api.post(f"/api/instructor/cohorts/{cohort_id}/exam-invites", {"label": label}, teacher)
    assert res.status_code == 201, res.content
    invite = res.json()
    cand = Session(client=Client(), username="")
    assert api.post(f"/api/exam/{invite['token']}/enter", session=cand).status_code == 200
    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 200
    config = api.get(f"/api/exam/{invite['token']}/ai-config", cand)
    assert config.status_code == 200, config.content
    for request, response in exchanges:
        res = Client().post(
            "/api/proxy/exchanges",
            data={
                "token": config.json()["token"],
                "tool": "claude_code",
                "model": "claude-sonnet-4-5",
                "client_id": "10.0.0.5",
                "input_tokens": 100,
                "output_tokens": 100,
                "request": request,
                "response": response,
            },
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {SECRET}",
        )
        assert res.status_code == 204, res.content
    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200
    return invite


def _setup(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite = _finished_attempt(api, teacher, cohort["id"], "지원자 A", MINE)
    return teacher, cohort, invite


def _path(cohort_id, invite_id, rest=""):
    return f"/api/instructor/cohorts/{cohort_id}/exam-invites/{invite_id}/report{rest}"


def _grade(api, teacher, cohort_id, invite_id):
    res = api.post(_path(cohort_id, invite_id, "/grade"), session=teacher)
    assert res.status_code == 200, res.content
    return res.json()


def _items(report):
    return {item["key"]: item for item in report["rubric"]["items"]}


def test_report_before_grading_has_scores_and_no_rubric(api):
    teacher, cohort, invite = _setup(api)

    res = api.get(_path(cohort["id"], invite["id"]), teacher)

    assert res.status_code == 200, res.content
    report = res.json()
    assert report["invite_id"] == invite["id"]
    assert report["label"] == "지원자 A"
    assert report["status"] == "finished"
    assert report["rubric"] is None
    assert report["edits"] == []
    assert report["local_model_unverified"] is False
    assert set(report["score"]) >= {"public_passed", "public_total", "hidden_passed", "hidden_total", "hidden_status", "final_percent"}
    patched = api.patch(_path(cohort["id"], invite["id"], "/rubric/decomposition"), {"score": 3, "reason": "확인"}, teacher)
    assert patched.status_code == 409


def test_grading_fills_four_items_with_scores_and_quoted_evidence(api):
    teacher, cohort, invite = _setup(api)

    report = _grade(api, teacher, cohort["id"], invite["id"])

    rubric = report["rubric"]
    assert rubric["grader"] == "fake"
    assert rubric["graded_at"]
    assert [item["key"] for item in rubric["items"]] == RUBRIC_KEYS
    sources = [text for pair in MINE for text in pair]
    for item in rubric["items"]:
        assert isinstance(item["label"], str) and item["label"]
        assert isinstance(item["score"], int) and not isinstance(item["score"], bool)
        assert 0 <= item["score"] <= 5
        assert item["llm_score"] == item["score"]
        assert item["edited"] is False
        assert item["evidence"], f"{item['key']} 에 근거 인용이 없다"
        for quote in item["evidence"]:
            assert quote.strip()
            assert any(quote in text for text in sources), quote
    assert report["edits"] == []
    assert api.get(_path(cohort["id"], invite["id"]), teacher).json()["rubric"] == rubric


def test_fake_grader_is_deterministic(api):
    teacher, cohort, invite = _setup(api)

    first = _grade(api, teacher, cohort["id"], invite["id"])
    second = _grade(api, teacher, cohort["id"], invite["id"])

    def strip(report):
        return [(i["key"], i["score"], i["evidence"]) for i in report["rubric"]["items"]]

    assert strip(first) == strip(second)


def test_get_grader_is_the_fake_one_without_a_key():
    from exams.grading import FakeGrader, get_grader

    with override_settings(GRADER_ANTHROPIC_KEY=""):
        assert isinstance(get_grader(), FakeGrader)


def test_instructor_edits_keep_the_llm_score_and_the_history(api):
    teacher, cohort, invite = _setup(api)
    llm = _items(_grade(api, teacher, cohort["id"], invite["id"]))["verification"]["llm_score"]
    first_to = (llm + 2) % 6
    second_to = (llm + 4) % 6

    res = api.patch(_path(cohort["id"], invite["id"], "/rubric/verification"), {"score": first_to, "reason": "검증 명령을 실제로 돌렸다"}, teacher)

    assert res.status_code == 200, res.content
    item = _items(res.json())["verification"]
    assert (item["score"], item["llm_score"], item["edited"]) == (first_to, llm, True)
    assert all(not i["edited"] for k, i in _items(res.json()).items() if k != "verification")
    edits = res.json()["edits"]
    assert [(e["key"], e["from_score"], e["to_score"], e["reason"]) for e in edits] == [
        ("verification", llm, first_to, "검증 명령을 실제로 돌렸다")
    ]
    assert edits[0]["by"] and edits[0]["at"]

    res = api.patch(_path(cohort["id"], invite["id"], "/rubric/verification"), {"score": second_to, "reason": "다시 봤다"}, teacher)

    assert res.status_code == 200, res.content
    item = _items(res.json())["verification"]
    assert (item["score"], item["llm_score"]) == (second_to, llm)
    assert [(e["from_score"], e["to_score"], e["reason"]) for e in res.json()["edits"]] == [
        (llm, first_to, "검증 명령을 실제로 돌렸다"),
        (first_to, second_to, "다시 봤다"),
    ]
    assert api.get(_path(cohort["id"], invite["id"]), teacher).json()["edits"] == res.json()["edits"]


def test_regrading_returns_to_the_llm_score_and_keeps_the_history(api):
    teacher, cohort, invite = _setup(api)
    llm = _items(_grade(api, teacher, cohort["id"], invite["id"]))["decomposition"]["llm_score"]
    edited_to = (llm + 3) % 6
    api.patch(_path(cohort["id"], invite["id"], "/rubric/decomposition"), {"score": edited_to, "reason": "나눔이 좋다"}, teacher)

    report = _grade(api, teacher, cohort["id"], invite["id"])

    item = _items(report)["decomposition"]
    assert (item["score"], item["llm_score"], item["edited"]) == (llm, llm, False)
    assert [(e["key"], e["to_score"], e["reason"]) for e in report["edits"]] == [("decomposition", edited_to, "나눔이 좋다")]


@pytest.mark.parametrize(
    "body",
    [
        {"score": 3, "reason": ""},
        {"score": 3, "reason": "   "},
        {"score": 3},
        {"score": 6, "reason": "너무 높다"},
        {"score": -1, "reason": "너무 낮다"},
    ],
    ids=["empty-reason", "blank-reason", "no-reason", "score-6", "score-minus"],
)
def test_invalid_edits_are_422_and_change_nothing(api, body):
    teacher, cohort, invite = _setup(api)
    before = _grade(api, teacher, cohort["id"], invite["id"])

    res = api.patch(_path(cohort["id"], invite["id"], "/rubric/decomposition"), body, teacher)

    assert res.status_code == 422, res.content
    after = api.get(_path(cohort["id"], invite["id"]), teacher).json()
    assert after["rubric"]["items"] == before["rubric"]["items"]
    assert after["edits"] == []


def test_unknown_item_is_404_and_another_orgs_report_is_404(api):
    teacher, cohort, invite = _setup(api)
    _grade(api, teacher, cohort["id"], invite["id"])

    assert api.patch(_path(cohort["id"], invite["id"], "/rubric/creativity"), {"score": 3, "reason": "x"}, teacher).status_code == 404

    outsider = api.login_instructor("other-owner", org="다른 회사")
    assert api.get(_path(cohort["id"], invite["id"]), outsider).status_code == 404
    assert api.post(_path(cohort["id"], invite["id"], "/grade"), session=outsider).status_code == 404
    patched = api.patch(_path(cohort["id"], invite["id"], "/rubric/decomposition"), {"score": 3, "reason": "x"}, outsider)
    assert patched.status_code == 404


def test_another_attempts_exchanges_are_not_used_as_evidence(api):
    teacher, cohort, invite = _setup(api)
    _finished_attempt(api, teacher, cohort["id"], "지원자 B", THEIRS)

    report = _grade(api, teacher, cohort["id"], invite["id"])

    quotes = [q for item in report["rubric"]["items"] for q in item["evidence"]]
    assert quotes
    assert not any("OTHER-CANDIDATE" in q or "kubectl" in q or "쿠버네티스" in q for q in quotes)
