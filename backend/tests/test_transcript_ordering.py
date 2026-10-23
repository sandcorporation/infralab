"""AI 대화 기록의 상한 — 오래된 것부터 버리기는 글자 순서가 아니라 시각 순서다."""

import pytest

from tests.api_helpers import S3, S3_CHECK_IDS, s3_results


def _submit(api, student, cohort_id, transcript):
    return api.post(
        f"/api/cohorts/{cohort_id}/scenarios/{S3}/submissions",
        {"agent_version": "0.3.0", "results": s3_results(set(S3_CHECK_IDS)), "ai_transcript": transcript},
        student,
    ).json()


def _setup(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    api.open_scenarios(teacher, cohort["id"], [S3])
    return cohort, student


def _tool(entries):
    return {"tool": "claude", "since": "", "truncated": False, "entries": entries}


@pytest.mark.django_db
def test_the_oldest_by_time_is_dropped_even_when_the_offset_notation_differs(api):
    cohort, student = _setup(api)
    # 09:00+09:00 은 00:00Z — 글자 순서로는 05:xxZ 보다 뒤라서 「최신」처럼 보이지만 실제로 가장 오래됐다.
    entries = [{"role": "user", "at": "2026-10-23T09:00:00+09:00", "text": "OLDEST"}]
    entries += [{"role": "user", "at": f"2026-10-23T05:{i // 60:02d}:{i % 60:02d}Z", "text": f"n{i}"} for i in range(500)]
    sub = _submit(api, student, cohort["id"], [_tool(entries)])
    kept = [e["text"] for e in sub["ai_transcript"][0]["entries"]]
    assert sub["ai_transcript"][0]["truncated"] is True
    assert "OLDEST" not in kept and "n0" in kept and len(kept) == 500


@pytest.mark.django_db
def test_entries_without_a_readable_time_keep_arrival_order(api):
    cohort, student = _setup(api)
    entries = [{"role": "user", "at": "2026-10-23T05:00:00Z", "text": "first"}]
    entries += [{"role": "assistant", "at": "", "text": f"blank{i}"} for i in range(3)]
    entries += [{"role": "user", "at": "어제 오후", "text": "garbled"}]
    entries += [{"role": "user", "at": f"2026-10-23T06:{i // 60:02d}:{i % 60:02d}Z", "text": f"n{i}"} for i in range(496)]
    # 501개 — 하나만 버린다: 가장 오래된 first.
    sub = _submit(api, student, cohort["id"], [_tool(entries)])
    kept = [e["text"] for e in sub["ai_transcript"][0]["entries"]]
    assert len(kept) == 500 and "first" not in kept
    assert kept[:4] == ["blank0", "blank1", "blank2", "garbled"]
