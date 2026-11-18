"""시험 모드 API.

- 강사(/api/instructor/…): 시험 설정(#70), 응시 링크(#70), 임시 토큰 회수(#72), 점수(#74), 감독 기록(#75),
  보고서(#76), 시험 대시보드(#77) — 내가 담당자인 조직의 시험 회차만
- 지원자(/api/exam/{token}…): 응시 상태·enter·start·finish(#71), AI 키 설정(#72), 숨은 검사(#74), 감독 신호(#75)
- AI 프록시 전용(/api/proxy/…): 임시 토큰 확인·기록(#72), 공유 비밀 `EXAM_PROXY_SECRET`
"""

from __future__ import annotations

import hmac

from django.conf import settings as django_settings
from django.contrib.auth import get_user, get_user_model, login
from django.db import transaction
from django.db.models import Count
from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from ninja import Router
from ninja.errors import HttpError
from ninja.security import HttpBearer
from ninja.responses import Status

from accounts.auth import check_origin, instructor_auth
from cohorts.api import _cohort_out as cohort_out
from cohorts.api import _cohorts_with_counts as cohorts_with_counts
from cohorts.api import compose_response
from cohorts.models import Cohort, Membership
from cohorts.services import managed_cohorts
from cohorts.schemas import CohortOut

from . import ai, grading, providers, services
from submissions.models import MAX_OUTPUT_CHARS, Submission

from .models import AIExchange, ExamEvent, ExamInvite, ExamRubric, RubricEdit
from .schemas import (
    ExamEnterOut,
    AiConfigOut,
    ExamEventIn,
    ExamEventOut,
    ExamProvidersOut,
    ExamInviteIn,
    ExamInviteOut,
    ExamReportOut,
    ExamScoreOut,
    FinalChecksOut,
    FinalResultsIn,
    ExamSettingsIn,
    ExamStartIn,
    ExamStatusOut,
    ProxyAuthorizeIn,
    ProxyExchangeIn,
    ProxyVerdictOut,
    RubricEditIn,
)

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
exam_router = Router(tags=["exam"])


class ProxyAuth(HttpBearer):
    """AI 프록시 전용 — `Authorization: Bearer <EXAM_PROXY_SECRET>`. 비밀이 비어 있으면 아무도 못 부른다."""

    def authenticate(self, request: HttpRequest, token: str):
        secret = django_settings.EXAM_PROXY_SECRET
        if secret and hmac.compare_digest(token.encode(), secret.encode()):
            return "proxy"
        return None


proxy_router = Router(tags=["proxy"], auth=ProxyAuth())

#: 응시마다 하나씩 만드는 숨은 사용자의 이름 앞부분 — sandcorp 로그인 사용자(`sandcorp:<sub>`)와 겹치지 않는다.
HIDDEN_USER_PREFIX = "exam-invite:"
AUTH_BACKEND = "django.contrib.auth.backends.ModelBackend"


# ---------- 강사 ----------


def _exam_cohort(request: HttpRequest, cohort_id: int) -> Cohort:
    """내 조직의 시험 회차. 남의 조직이면 404, 수업 묶음이면 422."""

    cohort = get_object_or_404(cohorts_with_counts(request.auth), pk=cohort_id)
    if cohort.kind != Cohort.Kind.EXAM:
        raise HttpError(422, "시험 회차가 아닙니다.")
    return cohort


def _status(invite: ExamInvite) -> str:
    if invite.revoked_at is not None:
        return "revoked"
    return services.attempt_status(invite)


def _invite_out(invite: ExamInvite, event_count: int = 0) -> ExamInviteOut:
    return ExamInviteOut(
        id=invite.id,
        label=invite.label,
        token=invite.token,
        status=_status(invite),
        created_at=invite.created_at,
        started_at=invite.started_at,
        finished_at=services.ended_at(invite),
        event_count=event_count,
    )


@instructor_router.get("/exam-providers", response=ExamProvidersOut)
def exam_providers(request: HttpRequest):
    return ExamProvidersOut(unavailable_tools=providers.unavailable_tools())


@instructor_router.put("/cohorts/{cohort_id}/exam-settings", response=CohortOut)
def put_exam_settings(request: HttpRequest, cohort_id: int, payload: ExamSettingsIn):
    cohort = _exam_cohort(request, cohort_id)
    missing = [t for t in providers.unavailable_tools() if t in payload.tools]
    if missing:
        raise HttpError(400, " ".join(providers.missing_message(t) for t in missing))
    cohort.exam_settings = payload.normalized()
    cohort.save(update_fields=["exam_settings"])
    return cohort_out(get_object_or_404(cohorts_with_counts(request.auth), pk=cohort_id))


@instructor_router.post("/cohorts/{cohort_id}/exam-invites", response={201: ExamInviteOut})
def create_exam_invite(request: HttpRequest, cohort_id: int, payload: ExamInviteIn):
    cohort = _exam_cohort(request, cohort_id)
    if not cohort.exam_settings:
        raise HttpError(409, "시험 설정을 먼저 저장하세요.")
    return Status(201, _invite_out(ExamInvite.objects.create(cohort=cohort, label=payload.label)))


@instructor_router.get("/cohorts/{cohort_id}/exam-invites", response=list[ExamInviteOut])
def list_exam_invites(request: HttpRequest, cohort_id: int):
    cohort = _exam_cohort(request, cohort_id)
    invites = cohort.exam_invites.annotate(event_count=Count("events"))
    return [_invite_out(i, i.event_count) for i in invites]


@instructor_router.delete("/cohorts/{cohort_id}/exam-invites/{invite_id}", response={204: None})
def revoke_exam_invite(request: HttpRequest, cohort_id: int, invite_id: int):
    cohort = _exam_cohort(request, cohort_id)
    invite = get_object_or_404(cohort.exam_invites, pk=invite_id)
    if invite.revoked_at is None and services.attempt_status(invite) == "finished":
        # 끝난 응시를 회수하면 상태가 「회수됨」으로 덮이고 보고서 길이 끊긴다(#154).
        raise HttpError(409, "끝난 응시는 회수할 수 없습니다.")
    if invite.revoked_at is None:
        invite.revoked_at = timezone.now()
        invite.save(update_fields=["revoked_at"])
    return HttpResponse(status=204)


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/ai-token/revoke", response={204: None})
def revoke_ai_token(request: HttpRequest, cohort_id: int, invite_id: int):
    """임시 토큰을 즉시 회수한다 — 프록시의 다음 확인부터 `revoked`."""

    cohort = _exam_cohort(request, cohort_id)
    invite = get_object_or_404(cohort.exam_invites, pk=invite_id)
    ai.revoke(invite)
    return HttpResponse(status=204)


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/score", response=ExamScoreOut)
def exam_score(request: HttpRequest, cohort_id: int, invite_id: int):
    """공개·숨은 점수와 최종 점수. 숨은 결과를 기다리는 동안 final_percent 는 null."""

    cohort = _exam_cohort(request, cohort_id)
    invite = get_object_or_404(cohort.exam_invites.select_related("cohort", "membership"), pk=invite_id)
    return services.score(invite)


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/events", response=list[ExamEventOut])
def exam_events(request: HttpRequest, cohort_id: int, invite_id: int):
    """지원자의 감독 기록을 시각순으로."""

    cohort = _exam_cohort(request, cohort_id)
    invite = get_object_or_404(cohort.exam_invites, pk=invite_id)
    return list(invite.events.all())


def _report_invite(request: HttpRequest, cohort_id: int, invite_id: int) -> ExamInvite:
    cohort = _exam_cohort(request, cohort_id)
    return get_object_or_404(cohort.exam_invites.select_related("cohort", "membership"), pk=invite_id)


def _local_llm_parts(invite: ExamInvite) -> list[dict]:
    """이 응시의 제출들에 붙은 local_llm 대화 기록(제출 순서)."""

    if invite.membership_id is None:
        return []
    out = []
    for sub in Submission.objects.filter(membership_id=invite.membership_id).order_by("id"):
        out.extend(t for t in (sub.ai_transcript or []) if t.get("tool") == "local_llm" and t.get("entries"))
    return out


def _exchanges(invite: ExamInvite) -> list[AIExchange]:
    """채점 재료 — 프록시 기록과, 제출에 붙은 local_llm 기록(저장하지 않는 AIExchange 로 바꾼 것)."""

    out = list(AIExchange.objects.filter(ai_token__invite=invite))
    for part in _local_llm_parts(invite):
        user: list[str] = []
        for e in part["entries"]:
            if e["role"] == "user":
                user.append(e["text"])
            elif user:
                out.append(AIExchange(tool="local_llm", model=part.get("model", ""), request="\n".join(user), response=e["text"]))
                user = []
        if user:
            out.append(AIExchange(tool="local_llm", model=part.get("model", ""), request="\n".join(user), response=""))
    return out


def _report(invite: ExamInvite) -> ExamReportOut:
    rubric = ExamRubric.objects.filter(invite=invite).first()
    return ExamReportOut(
        invite_id=invite.id,
        label=invite.label,
        status=_status(invite),
        score=services.score(invite),
        rubric=None
        if rubric is None
        else {
            "grader": rubric.grader,
            "graded_at": rubric.graded_at,
            "items": [{**item, "label": grading.RUBRIC_LABELS.get(item["key"], item["key"])} for item in rubric.items],
        },
        local_model_unverified=bool(_local_llm_parts(invite)),
        edits=list(invite.rubric_edits.all()),
    )


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/report", response=ExamReportOut)
def exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    """지원자 보고서. 채점 전이면 rubric 은 null."""

    return _report(_report_invite(request, cohort_id, invite_id))


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/grade", response=ExamReportOut)
def grade_exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    """이 응시의 프록시 기록으로 루브릭을 (다시) 채점한다. 점수는 새 LLM 점수로 돌아가고 수정 이력은 남는다."""

    invite = _report_invite(request, cohort_id, invite_id)
    grader = grading.get_grader()
    try:
        result = {item.key: item for item in grader.grade(_exchanges(invite))}
    except Exception as e:  # 채점기 바깥 서비스 실패
        raise HttpError(502, f"채점에 실패했습니다: {e}") from e
    items = []
    for key in grading.RUBRIC_KEYS:
        item = result.get(key) or grading.RubricItem(key=key, score=0)
        score = max(0, min(grading.MAX_SCORE, int(item.score)))
        items.append({"key": key, "score": score, "llm_score": score, "evidence": list(item.evidence), "edited": False})
    ExamRubric.objects.update_or_create(
        invite=invite,
        defaults={"grader": getattr(grader, "name", type(grader).__name__), "graded_at": timezone.now(), "items": items},
    )
    return _report(invite)


@instructor_router.patch("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/rubric/{key}", response=ExamReportOut)
def edit_rubric_item(request: HttpRequest, cohort_id: int, invite_id: int, key: str, payload: RubricEditIn):
    """담당자가 한 항목의 점수를 고치고 사유를 남긴다. LLM 점수는 그대로, 수정은 이력에 쌓인다."""

    invite = _report_invite(request, cohort_id, invite_id)
    if key not in grading.RUBRIC_KEYS:
        raise HttpError(404, "모르는 루브릭 항목입니다.")
    with transaction.atomic():
        rubric = ExamRubric.objects.select_for_update().filter(invite=invite).first()
        if rubric is None:
            raise HttpError(409, "먼저 채점하세요.")
        items = list(rubric.items)
        n = next((i for i, item in enumerate(items) if item["key"] == key), None)
        if n is None:
            raise HttpError(409, "이 항목은 채점되지 않았습니다.")
        user = request.auth
        RubricEdit.objects.create(
            invite=invite,
            key=key,
            from_score=items[n]["score"],
            to_score=payload.score,
            reason=payload.reason,
            by=(getattr(user, "display_name", "") or user.get_username()),
        )
        items[n] = {**items[n], "score": payload.score, "edited": True}
        rubric.items = items
        rubric.save(update_fields=["items"])
    return _report(invite)


@instructor_router.get("/exam-dashboard")
def exam_dashboard(request: HttpRequest):
    """내 조직들의 시험 회차마다 초대·시작·끝난 수와 끝난 응시의 최종 점수 분포(5구간). 회수한 링크는 세지 않는다."""

    now = timezone.now()
    cohorts = managed_cohorts(request.auth).filter(kind=Cohort.Kind.EXAM).order_by("id")
    rows = []
    for cohort in cohorts:
        invites = list(
            cohort.exam_invites.filter(revoked_at=None).select_related("cohort", "membership")
        )
        buckets = [0] * 5
        started = finished = 0
        for invite in invites:
            status = services.attempt_status(invite, now)
            if status == "invited":
                continue
            started += 1
            if status != "finished":
                continue
            finished += 1
            percent = services.score(invite)["final_percent"]
            if percent is not None:
                buckets[min(4, max(0, percent) // 20)] += 1
        rows.append(
            {
                "cohort_id": cohort.id,
                "org_id": cohort.org_id,
                "name": cohort.name,
                "invited": len(invites),
                "started": started,
                "finished": finished,
                "score_buckets": buckets,
            }
        )
    return rows


# ---------- 지원자 ----------


def _live_invite(token: str) -> ExamInvite:
    """회수되지 않은 응시 링크. 없거나 회수됐으면 404."""

    invite = ExamInvite.objects.select_related("cohort", "membership").filter(token=token, revoked_at=None).first()
    if invite is None:
        raise HttpError(404, "응시 링크가 올바르지 않거나 회수되었습니다.")
    return invite


def _exam_status_out(invite: ExamInvite) -> ExamStatusOut:
    now = timezone.now()
    settings = invite.cohort.exam_settings or {}
    return ExamStatusOut(
        cohort_id=invite.cohort_id,
        cohort_name=invite.cohort.name,
        status=services.attempt_status(invite, now),
        time_limit_minutes=int(settings.get("time_limit_minutes", 0)),
        tools=list(settings.get("tools", [])),
        proctoring=bool(settings.get("proctoring", False)),
        started_at=invite.started_at,
        deadline=services.deadline(invite),
        remaining_seconds=services.remaining_seconds(invite, now),
        server_time=now,
    )


def _candidate_invite(request: HttpRequest, token: str) -> ExamInvite:
    """이 브라우저가 `enter` 한 응시. `enter` 전이면 409, 다른 사람의 세션이면 403."""

    check_origin(request)
    invite = _live_invite(token)
    if invite.membership is None:
        raise HttpError(409, "응시 링크로 먼저 들어오세요.")
    user = get_user(request)
    if not user.is_authenticated:
        raise HttpError(409, "응시 링크로 먼저 들어오세요.")
    if user.pk != invite.membership.user_id:
        raise HttpError(403, "이 응시의 세션이 아닙니다.")
    return invite


@exam_router.get("/exam/{token}", auth=None, response=ExamStatusOut)
def exam_status(request: HttpRequest, token: str):
    return _exam_status_out(_live_invite(token))


@exam_router.post("/exam/{token}/enter", auth=None, response=ExamEnterOut)
def enter_exam(request: HttpRequest, token: str):
    """응시 한 번만을 위한 숨은 사용자로 세션을 연다. 같은 링크는 언제나 같은 사용자·같은 참여다.

    다른 사용자(강사·학생)로 로그인된 브라우저면 `login()` 이 그 세션을 지우고 새 키로 바꾼다 — 같은 때 옛 쿠키로
    나간 요청은 401 이고 SessionMiddleware 가 그 응답에서 세션 쿠키를 지워, 늦게 닿으면 새 응시 세션 쿠키까지
    없앤다(#122). 그래서 화면은 enter 가 끝난 뒤에만 인증 요청을 보내고, 바뀐 로그인은 `replaced_login` 으로 알린다.
    같은 응시 사용자로 다시 열면 `login()` 은 세션을 그대로 둔다.
    """

    check_origin(request)
    _live_invite(token)
    User = get_user_model()
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(token=token)
        if invite.membership is None:
            user, created = User.objects.get_or_create(
                username=f"{HIDDEN_USER_PREFIX}{invite.pk}", defaults={"display_name": invite.label}
            )
            if created:
                user.set_unusable_password()
                user.save(update_fields=["password"])
            membership, _ = Membership.objects.get_or_create(user=user, cohort=invite.cohort)
            invite.membership = membership
            invite.save(update_fields=["membership"])
        user = invite.membership.user
    current = get_user(request)
    replaced = bool(current.is_authenticated and current.pk != user.pk)
    login(request, user, backend=AUTH_BACKEND)
    return ExamEnterOut(**_exam_status_out(invite).dict(), replaced_login=replaced)


@exam_router.get("/exam/{token}/compose.yml", auth=None)
def exam_compose_file(request: HttpRequest, token: str):
    """응시자의 compose.yml — 로그인 쿠키 없이 응시 토큰만으로. 설치 프로그램에 붙여 넣는 주소다.

    회수됐거나 없는 링크 404, enter 전(응시자 없음) 409, 마감 뒤 410.
    """

    invite = _live_invite(token)
    if invite.membership is None:
        raise HttpError(409, "응시 링크로 먼저 들어오세요.")
    if services.attempt_status(invite) == "finished":
        raise HttpError(410, "끝난 시험입니다.")
    membership = Membership.objects.select_related("cohort").get(pk=invite.membership_id)
    return compose_response(membership)


@exam_router.post("/exam/{token}/start", auth=None, response=ExamStatusOut)
def start_exam(request: HttpRequest, token: str, payload: ExamStartIn):
    if not payload.consent:
        raise HttpError(422, "안내에 동의해야 시작할 수 있습니다.")
    invite = _candidate_invite(request, token)
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(pk=invite.pk)
        if services.attempt_status(invite) == "finished":
            raise HttpError(409, "이미 끝난 시험입니다.")
        if invite.started_at is None:
            now = timezone.now()
            invite.consented_at = now
            invite.started_at = now
            invite.save(update_fields=["consented_at", "started_at"])
    return _exam_status_out(invite)


@exam_router.post("/exam/{token}/finish", auth=None, response=ExamStatusOut)
def finish_exam(request: HttpRequest, token: str):
    invite = _candidate_invite(request, token)
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(pk=invite.pk)
        if invite.started_at is None:
            raise HttpError(409, "시작하지 않은 시험입니다.")
        if invite.finished_at is None:
            invite.finished_at = services.ended_at(invite) or timezone.now()
            invite.save(update_fields=["finished_at"])
        ai.revoke(invite, invite.finished_at)
    return _exam_status_out(invite)


@exam_router.get("/exam/{token}/ai-config", auth=None, response=AiConfigOut)
def exam_ai_config(request: HttpRequest, token: str):
    """응시 중에만 허용 도구마다 AI 키 설정을 준다. 시작 전·마감 뒤·임시 토큰 회수 뒤에는 409."""

    invite = _candidate_invite(request, token)
    if services.attempt_status(invite) != "in_progress":
        raise HttpError(409, "응시 중에만 AI 키 설정을 받을 수 있습니다.")
    ai_token = ai.issue(invite)
    if ai_token.revoked_at is not None:
        raise HttpError(409, "임시 토큰이 회수되었습니다.")
    return AiConfigOut(proxy_url=ai.proxy_url(), token=ai_token.token, tools=ai.tool_configs(invite, ai_token.token))


@exam_router.get("/exam/{token}/final-checks", auth=None, response=FinalChecksOut)
def exam_final_checks(request: HttpRequest, token: str):
    """마감 뒤에만 열린 시나리오별 숨은 검사 정의를 준다(공개 검사는 없음). 응시 중에는 409."""

    invite = _candidate_invite(request, token)
    if services.attempt_status(invite) != "finished":
        raise HttpError(409, "응시가 끝난 뒤에만 받을 수 있습니다.")
    return {
        "scenarios": [
            {"scenario_id": s.id, "checks": s.hidden_check_definitions(), "scripts": s.hidden_check_scripts()}
            for s in services.hidden_scenarios(invite)
        ]
    }


@exam_router.post("/exam/{token}/final-results", auth=None, response={204: None})
def exam_final_results(request: HttpRequest, token: str, payload: FinalResultsIn):
    """마감 뒤 숨은 검사 결과를 한 번 받는다. 마감 전·두 번째는 409, 검사 id 가 맞지 않으면 422."""

    invite = _candidate_invite(request, token)
    with transaction.atomic():
        invite = ExamInvite.objects.select_for_update(of=("self",)).select_related("cohort", "membership").get(pk=invite.pk)
        if services.attempt_status(invite) != "finished":
            raise HttpError(409, "응시가 끝난 뒤에만 올릴 수 있습니다.")
        if invite.final_results_at is not None:
            raise HttpError(409, "숨은 검사 결과는 이미 받았습니다.")
        expected = {s.id: s for s in services.hidden_scenarios(invite)}
        if not expected:
            raise HttpError(409, "이 응시에는 숨은 검사가 없습니다.")
        got = [s.scenario_id for s in payload.scenarios]
        if sorted(got) != sorted(expected):
            raise HttpError(422, f"시나리오가 맞지 않습니다 (기대 {sorted(expected)}, 받음 {sorted(got)})")
        stored: dict[str, list[dict]] = {}
        for item in payload.scenarios:
            scenario = expected[item.scenario_id]
            ids = [c.id for c in scenario.hidden_checks]
            if sorted(r.id for r in item.results) != sorted(ids):
                raise HttpError(422, f"{item.scenario_id}: 숨은 검사 결과가 맞지 않습니다.")
            by_id = {r.id: r for r in item.results}
            stored[item.scenario_id] = [
                {
                    "check_id": cid,
                    "pass": by_id[cid].pass_,
                    "output": by_id[cid].output[:MAX_OUTPUT_CHARS],
                    "exit_code": by_id[cid].exit_code,
                    "error": by_id[cid].error[:500],
                }
                for cid in ids
            ]
        invite.final_results = stored
        invite.final_results_at = timezone.now()
        invite.save(update_fields=["final_results", "final_results_at"])
    return HttpResponse(status=204)


@exam_router.post("/exam/{token}/events", auth=None, response={204: None})
def exam_event(request: HttpRequest, token: str, payload: ExamEventIn):
    """응시 중 감독 신호를 남긴다. 시작 전·마감 뒤는 409, 감독을 끈 회차는 204 지만 남기지 않는다."""

    invite = _candidate_invite(request, token)
    if services.attempt_status(invite) != "in_progress":
        raise HttpError(409, "응시 중에만 감독 신호를 보낼 수 있습니다.")
    if (invite.cohort.exam_settings or {}).get("proctoring"):
        ExamEvent.objects.create(invite=invite, kind=payload.kind, detail=payload.detail)
    return HttpResponse(status=204)


# ---------- AI 프록시 전용 ----------


@proxy_router.post("/proxy/authorize", response=ProxyVerdictOut)
def proxy_authorize(request: HttpRequest, payload: ProxyAuthorizeIn):
    """임시 토큰으로 온 요청 하나를 허용할지. 허용이면 고정 모델과 남은 사용량(한도 0 이면 null)."""

    v = ai.verdict(payload.token, payload.tool, payload.client_id)
    return ProxyVerdictOut(allowed=v.allowed, reason=v.reason, model=v.model, remaining_tokens=v.remaining_tokens)


@proxy_router.post("/proxy/exchanges", response={204: None})
def proxy_exchanges(request: HttpRequest, payload: ProxyExchangeIn):
    """프록시가 넘긴 요청·응답·사용량을 채점 재료로 적고 사용량을 한도에서 깎는다. 모르는 토큰이면 404."""

    if not ai.record_exchange(
        payload.token,
        tool=payload.tool,
        model=payload.model,
        client_id=payload.client_id,
        input_tokens=payload.input_tokens,
        output_tokens=payload.output_tokens,
        request=payload.request,
        response=payload.response,
    ):
        raise HttpError(404, "모르는 임시 토큰입니다.")
    return HttpResponse(status=204)
