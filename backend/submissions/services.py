"""다른 앱이 쓰는 제출 조회. 「최신」은 어디서나 id 가 큰 것이다(시계가 아니라 저장 순서).

점수는 어디서나 지금 시나리오의 검사 정의에 맞춰 다시 센다(`score`) — 검사 정의가 바뀐 뒤 옛 제출도
n/현재 total 로 읽히고, 격자·이력·상세가 같은 수를 보인다.
"""

from __future__ import annotations

from datetime import datetime, timezone

from django.db.models import Max

from cohorts.models import Cohort, Membership
from scenarios import registry
from scenarios.loader import Scenario

from ninja.errors import HttpError

from .models import MAX_TRANSCRIPT_ENTRIES, MAX_TRANSCRIPT_ENTRY_CHARS, MAX_TRANSCRIPT_TOTAL_CHARS, Submission


def latest_submissions_by_scenario(membership: Membership) -> dict[str, Submission]:
    """참여자의 시나리오별 최신 제출. 제출이 없는 시나리오는 빠진다."""

    latest_ids = (
        Submission.objects.filter(membership=membership)
        .values("scenario_id")
        .annotate(latest_id=Max("id"))
        .values_list("latest_id", flat=True)
    )
    return {s.scenario_id: s for s in Submission.objects.filter(id__in=list(latest_ids))}


def latest_submissions_for_cohort(cohort: Cohort) -> dict[tuple[int, str], Submission]:
    """기수 전체의 (참여 id, 시나리오 id) → 최신 제출. 쿼리 두 번 — 격자가 참여자 수만큼 되묻지 않게."""

    latest_ids = (
        Submission.objects.filter(membership__cohort=cohort)
        .values("membership_id", "scenario_id")
        .annotate(latest_id=Max("id"))
        .values_list("latest_id", flat=True)
    )
    return {(s.membership_id, s.scenario_id): s for s in Submission.objects.filter(id__in=list(latest_ids))}


def passed_against(submission: Submission, scenario: Scenario) -> int:
    ids = {c.id for c in scenario.checks}
    return sum(1 for r in submission.results if r.get("pass") and r.get("check_id") in ids)


_EPOCH = datetime.min.replace(tzinfo=timezone.utc)


def _parse_at(text: str) -> datetime | None:
    """발화 시각(ISO 8601, Z 또는 오프셋). 시간대가 없으면 UTC 로 본다. 읽지 못하면 None."""

    try:
        dt = datetime.fromisoformat(text.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def has_transcript(submission: Submission) -> bool:
    return any(t.get("entries") for t in (submission.ai_transcript or []))


def normalize_transcript(raw: list | None) -> list[dict] | None:
    """제출에 붙은 AI 대화 기록을 상한에 맞춰 저장 모양으로 바꾼다. 발화가 하나도 없으면 None(기록 없음).

    발화 하나는 MAX_TRANSCRIPT_ENTRY_CHARS 로 자르고, 두 도구를 합친 발화 수·총 길이가 상한을 넘으면 가장 오래된
    발화부터 버린다. 자르거나 버린 도구는 truncated 를 켠다. 도구는 하나씩만 올 수 있다.
    """

    if not raw:
        return None
    tools = [t.tool for t in raw]
    if len(set(tools)) != len(tools):
        raise HttpError(422, "AI 대화 기록은 도구마다 하나씩만 올릴 수 있습니다.")

    parts = []
    for t in raw:
        entries = []
        truncated = t.truncated
        for e in t.entries:
            text = e.text
            if len(text) > MAX_TRANSCRIPT_ENTRY_CHARS:
                text = text[:MAX_TRANSCRIPT_ENTRY_CHARS] + "\n…(truncated)"
                truncated = True
            entries.append({"role": e.role, "at": e.at, "text": text})
        if entries:
            parts.append({"tool": t.tool, "since": t.since, "truncated": truncated, "entries": entries})
    if not parts:
        return None

    # 오래된 것부터 버린다 — at 을 시각으로 읽어 견준다(글자 순서는 시간대 표기가 다르면 틀린다). 읽지 못하는 at 은
    # 같은 도구에서 바로 앞 발화의 시각을 따라 도착 순서를 지킨다. 같은 시각이면 올라온 순서.
    flat = []
    n = 0
    for i, p in enumerate(parts):
        last = _EPOCH
        for j, e in enumerate(p["entries"]):
            last = _parse_at(e["at"]) or last
            flat.append((last, n, i, j))
            n += 1
    total_entries = len(flat)
    total_chars = sum(len(parts[i]["entries"][j]["text"]) for _, _, i, j in flat)
    dropped: set[tuple[int, int]] = set()
    for _, _, i, j in sorted(flat):
        if total_entries <= MAX_TRANSCRIPT_ENTRIES and total_chars <= MAX_TRANSCRIPT_TOTAL_CHARS:
            break
        dropped.add((i, j))
        total_entries -= 1
        total_chars -= len(parts[i]["entries"][j]["text"])
        parts[i]["truncated"] = True
    out = []
    for i, p in enumerate(parts):
        kept = [e for j, e in enumerate(p["entries"]) if (i, j) not in dropped]
        if kept:
            out.append({**p, "entries": kept})
    return out or None


def score(submission: Submission) -> tuple[int, int]:
    """(통과, 전체). 시나리오가 저장소에 있으면 지금 정의로 다시 세고, 없으면 저장된 값."""

    scenario = registry.get(submission.scenario_id)
    if scenario is None:
        return submission.passed, submission.total
    return passed_against(submission, scenario), len(scenario.checks)
