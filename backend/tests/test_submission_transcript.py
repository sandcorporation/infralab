"""제출에 붙는 AI 대화 기록 — 저장·상한·has_transcript, 학생 상세와 강사 상세·격자에 그대로 나온다."""

import pytest

from tests.api_helpers import S3, S3_CHECK_IDS, s3_results


def _setup(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], [S3])
    return teacher, cohort, student


def _submit(api, student, cohort_id, transcript=None, **extra):
    body = {"agent_version": "0.3.0", "results": s3_results(set(S3_CHECK_IDS)), **extra}
    if transcript is not None:
        body["ai_transcript"] = transcript
    return api.post(f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions", body, student)


def _entry(role, text, at="2026-10-23T07:01:00.000Z"):
    return {"role": role, "at": at, "text": text}


CLAUDE = {
    "tool": "claude",
    "since": "2026-10-23T07:00:00Z",
    "truncated": False,
    "entries": [_entry("user", "버킷 만들어 줘"), _entry("assistant", "aws s3 mb 로 만들겠습니다.", "2026-10-23T07:01:03.000Z")],
}


@pytest.mark.django_db
def test_transcript_is_stored_and_shown_as_sent_to_student_and_instructor(api):
    teacher, cohort, student = _setup(api)
    res = _submit(api, student, cohort["id"], [CLAUDE])
    assert res.status_code == 201, res.content
    sub = res.json()
    assert sub["has_transcript"] is True
    assert sub["ai_transcript"] == [CLAUDE]

    latest = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions/latest", student).json()
    assert latest["ai_transcript"] == [CLAUDE] and latest["has_transcript"] is True
    detail = api.get(f"/api/instructor/submissions/{sub['id']}", teacher).json()
    assert detail["ai_transcript"] == [CLAUDE] and detail["has_transcript"] is True


@pytest.mark.django_db
def test_submission_without_a_transcript_says_so(api):
    teacher, cohort, student = _setup(api)
    plain = _submit(api, student, cohort["id"]).json()
    assert plain["has_transcript"] is False and plain["ai_transcript"] is None
    # 켰지만 발화가 없는 기록(도구는 읽혔는데 대화가 없음)도 「기록 없음」이다.
    empty = _submit(api, student, cohort["id"], [{**CLAUDE, "entries": []}]).json()
    assert empty["has_transcript"] is False and empty["ai_transcript"] is None


@pytest.mark.django_db
def test_has_transcript_is_in_history_and_grid_cells(api):
    teacher, cohort, student = _setup(api)
    _submit(api, student, cohort["id"])
    with_t = _submit(api, student, cohort["id"], [CLAUDE]).json()

    history = api.get(f"/api/cohorts/{cohort['id']}/scenarios/{S3}/submissions", student).json()
    assert [h["has_transcript"] for h in history] == [True, False]
    assert "ai_transcript" not in history[0]  # 요약에는 본문이 없다

    grid = api.get(f"/api/instructor/cohorts/{cohort['id']}/grid", teacher).json()
    assert grid["rows"][0]["cells"][S3]["has_transcript"] is True

    mid = _membership_id(api, teacher, cohort["id"])
    teacher_history = api.get(
        f"/api/instructor/cohorts/{cohort['id']}/participants/{mid}/scenarios/{S3}/submissions", teacher
    ).json()
    assert [h["has_transcript"] for h in teacher_history] == [True, False]
    assert with_t["id"] == teacher_history[0]["id"]

    # 다음 제출이 기록 없이 오면 격자 칸의 기록 유무도 최신 것을 따른다.
    _submit(api, student, cohort["id"])
    grid = api.get(f"/api/instructor/cohorts/{cohort['id']}/grid", teacher).json()
    assert grid["rows"][0]["cells"][S3]["has_transcript"] is False


def _membership_id(api, teacher, cohort_id):
    return api.get(f"/api/instructor/cohorts/{cohort_id}/grid", teacher).json()["rows"][0]["membership_id"]


@pytest.mark.django_db
def test_entry_count_and_total_length_are_capped_with_truncated_set(api):
    teacher, cohort, student = _setup(api)
    many = [_entry("user", f"{i:04d} 질문", f"2026-10-23T07:{i // 60:02d}:{i % 60:02d}.000Z") for i in range(700)]
    sub = _submit(api, student, cohort["id"], [{**CLAUDE, "entries": many}]).json()
    kept = sub["ai_transcript"][0]["entries"]
    assert sub["ai_transcript"][0]["truncated"] is True
    assert len(kept) <= 500
    # 오래된 것부터 버린다 — 최신 발화가 남는다.
    assert kept[-1]["text"].startswith("0699") and not kept[0]["text"].startswith("0000")

    big = "x" * 20_000
    heavy = [_entry("assistant", f"{i}{big}", f"2026-10-23T07:{i:02d}:00.000Z") for i in range(30)]  # 60만 자
    sub = _submit(api, student, cohort["id"], [{**CLAUDE, "entries": heavy}]).json()
    entries = sub["ai_transcript"][0]["entries"]
    assert sub["ai_transcript"][0]["truncated"] is True
    assert sum(len(e["text"]) for e in entries) <= 250_000
    assert entries[-1]["text"].startswith("29")


@pytest.mark.django_db
def test_a_single_huge_utterance_is_clipped_and_marked(api):
    _, cohort, student = _setup(api)
    sub = _submit(api, student, cohort["id"], [{**CLAUDE, "entries": [_entry("assistant", "x" * 100_000)]}]).json()
    assert sub["ai_transcript"][0]["truncated"] is True
    assert len(sub["ai_transcript"][0]["entries"][0]["text"]) <= 20_100


@pytest.mark.django_db
def test_client_truncated_flag_is_kept_and_bad_shapes_are_rejected(api):
    _, cohort, student = _setup(api)
    sub = _submit(api, student, cohort["id"], [{**CLAUDE, "truncated": True}]).json()
    assert sub["ai_transcript"][0]["truncated"] is True

    assert _submit(api, student, cohort["id"], [{**CLAUDE, "tool": "gemini"}]).status_code == 422
    assert _submit(api, student, cohort["id"], [{**CLAUDE, "entries": [_entry("system", "x")]}]).status_code == 422
    assert _submit(api, student, cohort["id"], "not a list").status_code == 422
    # 같은 도구가 두 번 오면 마지막 것을 쓰지 않고 거절한다 — 도구마다 하나다.
    assert _submit(api, student, cohort["id"], [CLAUDE, CLAUDE]).status_code == 422
