"""로컬 LLM — 제출의 local_llm 대화 기록, ai-config 의 local_llm 항목, 보고서의 「조건 미검증」 표시.

target: backend/tests/test_spec_exam_local_llm.py
AC: #79: backend 제출이 tool: "local_llm"(선택 model) 기록을 받는다
AC: #79: 로컬 LLM 을 허용한 회차의 ai-config 에 local_llm 항목(env 의 OPENAI_BASE_URL 이 /llm/v1 로 끝남)이 있다
AC: #79: 응시의 제출에 local_llm 기록이 있으면 보고서 local_model_unverified: true, 없으면 false
AC: #79: 응시 제출의 local_llm 기록이 루브릭 채점 재료가 된다(근거 인용이 그 기록 안의 글)
AC: #79: local_llm 을 허용한 회차의 local_llm 기록은 ai_outside_proxy 신호를 남기지 않고, 허용하지 않은 회차면 남긴다

학생·지원자의 제출 API 와 담당자 보고서 API 를 테스트 클라이언트로 부른다. agent 쪽 중계·기록은
agent/spec_exam_llm_relay_test.go 가 본다. 보고서 화면의 「로컬 모델 — 조건 미검증」 글은 「손 확인」이다.
"""

import pytest
from django.test import Client, override_settings

from tests.api_helpers import S3, S3_CHECK_IDS, Session, s3_results

pytestmark = [pytest.mark.django_db, pytest.mark.usefixtures("grader_settings")]

LOCAL_TRANSCRIPT = {
    "tool": "local_llm",
    "model": "qwen2.5-coder:7b",
    "since": "2026-11-18T09:00:00Z",
    "truncated": False,
    "entries": [
        {"role": "user", "at": "2026-11-18T09:01:00Z", "text": "lab-site 버킷을 만들어 줘"},
        {"role": "assistant", "at": "2026-11-18T09:01:04Z", "text": "aws s3 mb s3://lab-site 를 실행하세요."},
    ],
}
EXAM_SETTINGS = {
    "time_limit_minutes": 60,
    "tools": ["local_llm"],
    "models": {},
    "proctoring": False,
    "hidden_checks": False,
    "ai_token_limit": 0,
}


@pytest.fixture
def grader_settings():
    with override_settings(GRADER_ANTHROPIC_KEY="", EXAM_PROXY_SECRET="proxy-secret-for-tests"):
        yield


def _submit(api, who, cohort_id, transcript):
    body = {"agent_version": "0.4.0", "results": s3_results(set(S3_CHECK_IDS))}
    if transcript is not None:
        body["ai_transcript"] = transcript
    return api.post(f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions", body, who)


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
    assert api.post(f"/api/exam/{invite['token']}/start", {"consent": True}, cand).status_code == 200
    return invite, cand


@pytest.mark.skip(reason="#79")
def test_submission_takes_a_local_llm_transcript_with_its_model(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], [S3])

    res = _submit(api, student, cohort["id"], [LOCAL_TRANSCRIPT])

    assert res.status_code == 201, res.content
    stored = res.json()["ai_transcript"]
    assert [t["tool"] for t in stored] == ["local_llm"]
    assert stored[0]["model"] == "qwen2.5-coder:7b"
    assert [(e["role"], e["text"]) for e in stored[0]["entries"]] == [
        ("user", "lab-site 버킷을 만들어 줘"),
        ("assistant", "aws s3 mb s3://lab-site 를 실행하세요."),
    ]
    latest = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions/latest", student).json()
    assert latest["ai_transcript"][0]["model"] == "qwen2.5-coder:7b"
    # model 은 선택이다.
    without_model = {k: v for k, v in LOCAL_TRANSCRIPT.items() if k != "model"}
    assert _submit(api, student, cohort["id"], [without_model]).status_code == 201


@pytest.mark.skip(reason="#79")
def test_ai_config_has_a_local_llm_entry_through_the_agent(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])

    res = api.get(f"/api/exam/{invite['token']}/ai-config", cand)

    assert res.status_code == 200, res.content
    tools = res.json()["tools"]
    assert [t["tool"] for t in tools] == ["local_llm"]
    local = tools[0]
    assert local["model"] == ""
    assert local["config_toml"] == ""
    assert local["env"]["OPENAI_BASE_URL"].endswith("/llm/v1")
    assert "OPENAI_API_KEY" in local["env"]


@pytest.mark.skip(reason="#79")
def test_report_marks_local_model_as_unverified_only_when_used(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    local_invite, local_cand = _attempt(api, teacher, cohort["id"], "로컬 모델 사용")
    plain_invite, plain_cand = _attempt(api, teacher, cohort["id"], "AI 안 씀")
    assert _submit(api, local_cand, cohort["id"], [LOCAL_TRANSCRIPT]).status_code == 201
    assert _submit(api, plain_cand, cohort["id"], None).status_code == 201
    for invite, cand in ((local_invite, local_cand), (plain_invite, plain_cand)):
        assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200

    def report(invite_id):
        res = api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite_id}/report", teacher)
        assert res.status_code == 200, res.content
        return res.json()

    assert report(local_invite["id"])["local_model_unverified"] is True
    assert report(plain_invite["id"])["local_model_unverified"] is False


@pytest.mark.skip(reason="#79")
def test_local_llm_transcript_is_grading_material(api):
    teacher = api.login_instructor()
    cohort = _exam(api, teacher)
    invite, cand = _attempt(api, teacher, cohort["id"])
    assert _submit(api, cand, cohort["id"], [LOCAL_TRANSCRIPT]).status_code == 201
    assert api.post(f"/api/exam/{invite['token']}/finish", session=cand).status_code == 200

    res = api.post(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}/report/grade", session=teacher)

    assert res.status_code == 200, res.content
    rubric = res.json()["rubric"]
    assert rubric["grader"] == "fake"
    quotes = [q for item in rubric["items"] for q in item["evidence"]]
    assert quotes, "로컬 LLM 기록이 채점 재료로 쓰이지 않았다"
    sources = [e["text"] for e in LOCAL_TRANSCRIPT["entries"]]
    for quote in quotes:
        assert quote.strip()
        assert any(quote in text for text in sources), quote


@pytest.mark.parametrize("tools, signalled", [(["local_llm"], False), (["claude_code"], True)], ids=["allowed", "not-allowed"])
@pytest.mark.skip(reason="#79")
def test_local_llm_transcript_and_the_outside_proxy_signal(api, tools, signalled):
    teacher = api.login_instructor()
    models = {"claude_code": "claude-sonnet-4-5"} if "claude_code" in tools else {}
    cohort = _exam(api, teacher, {**EXAM_SETTINGS, "tools": tools, "models": models, "proctoring": True})
    invite, cand = _attempt(api, teacher, cohort["id"])

    assert _submit(api, cand, cohort["id"], [LOCAL_TRANSCRIPT]).status_code == 201

    res = api.get(f"/api/instructor/cohorts/{cohort['id']}/exam-invites/{invite['id']}/events", teacher)
    assert res.status_code == 200, res.content
    outside = [e for e in res.json() if e["kind"] == "ai_outside_proxy"]
    if signalled:
        assert len(outside) == 1 and "local_llm" in outside[0]["detail"]
    else:
        assert outside == []
