"""감독 신호 중 서버가 남기는 「프록시 밖 AI 사용」(#75)."""

from __future__ import annotations

from cohorts.models import Cohort, Membership

from .models import AIExchange, ExamEvent, ExamInvite

#: 대화 기록의 도구 이름 → 시험 설정·프록시 기록의 도구 이름.
TRANSCRIPT_TOOLS = {"claude": "claude_code", "codex": "codex"}


def check_outside_proxy(membership: Membership, transcript: list[dict] | None) -> None:
    """시험 회차 제출의 대화 기록에 발화가 있는 도구가 허용되지 않았거나 프록시 기록에 없으면 신호를 남긴다."""

    if not transcript or membership.cohort.kind != Cohort.Kind.EXAM:
        return
    invite = ExamInvite.objects.filter(membership=membership).select_related("cohort").first()
    if invite is None:
        return
    settings = invite.cohort.exam_settings or {}
    if not settings.get("proctoring"):
        return
    allowed = set(settings.get("tools", []))
    for part in transcript:
        if not part.get("entries"):
            continue
        name = part["tool"]
        tool = TRANSCRIPT_TOOLS.get(name, name)
        if tool == "local_llm" and tool in allowed:
            continue  # 로컬 LLM 은 프록시를 지나지 않는다.
        if tool in allowed and AIExchange.objects.filter(ai_token__invite=invite, tool=tool).exists():
            continue
        ExamEvent.objects.create(invite=invite, kind="ai_outside_proxy", detail=name)
