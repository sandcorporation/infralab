"""개인 연습 API(/api/practice…) — 연습 묶음 참여(#132), 피드백(#134), 내 기록(#136).

연습 묶음의 시나리오 화면·환경 준비·제출은 기존 학생 경로(`/api/cohorts/<id>/…`)를 그대로 쓴다.
"""

from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

from django.db import IntegrityError, transaction
from django.utils import timezone
from django.http import HttpRequest
from ninja import Router, Schema
from ninja.errors import HttpError

from accounts.auth import jwt_auth
from cohorts.models import Cohort, Membership
from cohorts.schemas import JoinOut
from exams import grading
from exams.api import HIDDEN_USER_PREFIX
from exams.models import LLMUsage
from scenarios import registry
from submissions.models import Submission
from submissions.services import has_transcript, passed_against, score

from .models import PracticeFeedback
from .services import practice_cohort

practice_router = Router(tags=["practice"], auth=jwt_auth)


# ---------- 연습 묶음 참여 ----------


class PracticeStatusOut(Schema):
    cohort_id: int
    name: str
    #: 내가 연습 묶음에 참여했는가(「연습 시작」을 눌렀는가).
    joined: bool
    #: 연습에 열린 시나리오 수(카탈로그 전체). 참여 전 빈 상태에 보인다.
    scenario_count: int


@practice_router.get("/practice", response=PracticeStatusOut)
def practice_status(request: HttpRequest):
    c = practice_cohort()
    joined = Membership.objects.filter(user=request.auth, cohort=c).exists()
    return PracticeStatusOut(
        cohort_id=c.id, name=c.name, joined=joined, scenario_count=len(registry.all_scenarios())
    )


@practice_router.post("/practice/join", response=JoinOut)
def join_practice(request: HttpRequest):
    """「연습 시작」 — 연습 묶음에 참여한다. 가입 링크가 없고, 다시 눌러도 같은 참여(에이전트 토큰 그대로)."""

    if request.auth.username.startswith(HIDDEN_USER_PREFIX):
        raise HttpError(403, "응시 전용 계정은 개인 연습에 들어올 수 없습니다.")
    c = practice_cohort()
    if Membership.objects.filter(user=request.auth, cohort=c).exists():
        return JoinOut(cohort_id=c.id, name=c.name, created=False)
    try:
        with transaction.atomic():
            Membership.objects.create(user=request.auth, cohort=c)
    except IntegrityError:
        # 두 탭에서 동시에 눌렀다 — 먼저 만든 쪽이 이겼고 결과는 같다.
        return JoinOut(cohort_id=c.id, name=c.name, created=False)
    return JoinOut(cohort_id=c.id, name=c.name, created=True)


# ---------- 피드백 ----------


#: 사용자당 하루 피드백 수(Asia/Seoul 날짜 기준). 실패한 채점은 세지 않는다.
FEEDBACK_DAILY_LIMIT = 5
FEEDBACK_LIMIT_MESSAGE = "오늘 피드백 5회를 다 썼습니다 — 내일 다시"
SEOUL = ZoneInfo("Asia/Seoul")


class FeedbackItemOut(Schema):
    key: str
    label: str
    score: int
    evidence: list[str]


class FeedbackOut(Schema):
    submission_id: int
    grader: str
    graded_at: datetime
    items: list[FeedbackItemOut]


class FeedbackQuotaOut(Schema):
    limit: int
    used: int
    remaining: int


def _today() -> date:
    """「오늘」(Asia/Seoul). 요청 때마다 `timezone.now()` 를 부른다."""

    return timezone.localtime(timezone.now(), SEOUL).date()


def _used(user, day: date) -> int:
    return PracticeFeedback.objects.filter(submission__membership__user=user, day=day).count()


def _my_practice_submission(request: HttpRequest, submission_id: int) -> Submission:
    """내 연습 묶음 제출. 남의 것·연습이 아닌 묶음의 것은 404."""

    sub = (
        Submission.objects.filter(
            id=submission_id,
            membership__user=request.auth,
            membership__cohort__kind=Cohort.Kind.PRACTICE,
        )
        .only("id", "ai_transcript")
        .first()
    )
    if sub is None:
        raise HttpError(404, "연습 제출을 찾을 수 없습니다.")
    return sub


def _feedback_out(fb: PracticeFeedback) -> FeedbackOut:
    return FeedbackOut(
        submission_id=fb.submission_id,
        grader=fb.grader,
        graded_at=fb.graded_at,
        items=[
            FeedbackItemOut(
                key=item["key"],
                label=grading.RUBRIC_LABELS.get(item["key"], item["key"]),
                score=item["score"],
                evidence=list(item.get("evidence") or []),
            )
            for item in fb.items
        ],
    )


@practice_router.post("/practice/submissions/{submission_id}/feedback", response=FeedbackOut)
def request_feedback(request: HttpRequest, submission_id: int):
    """「피드백 받기」 — 제출의 AI 대화 기록을 루브릭으로 채점해 저장한다. 이미 있으면 그것(한도를 쓰지 않음).

    「남은 횟수 확인 → 채점 → 저장」 을 사용자 행 잠금 안에서 하므로 동시에 눌러도 하루 한도와 제출당 하나가 지켜진다.
    """

    sub = _my_practice_submission(request, submission_id)
    existing = PracticeFeedback.objects.filter(submission=sub).first()
    if existing is not None:
        return _feedback_out(existing)
    turns = grading.turns_from_transcript(sub.ai_transcript)
    if not turns:
        raise HttpError(422, "AI 대화 기록이 없는 제출입니다. AI 대화 함께 제출을 켜고 다시 제출하세요.")

    user_model = type(request.auth)
    with transaction.atomic():
        user_model.objects.select_for_update().get(pk=request.auth.pk)
        existing = PracticeFeedback.objects.filter(submission=sub).first()
        if existing is not None:
            return _feedback_out(existing)
        day = _today()
        if _used(request.auth, day) >= FEEDBACK_DAILY_LIMIT:
            raise HttpError(429, FEEDBACK_LIMIT_MESSAGE)
        grader = grading.get_grader()
        try:
            result = {item.key: item for item in grader.grade_turns(turns)}
        except Exception as e:  # 채점기 바깥 서비스 실패 — 행을 만들지 않으니 세지 않는다
            raise HttpError(502, f"채점에 실패했습니다: {e}") from e
        grading.record_usage(grader, LLMUsage.PURPOSE_PRACTICE_FEEDBACK, submission=sub)
        items = []
        for key in grading.RUBRIC_KEYS:
            item = result.get(key) or grading.RubricItem(key=key, score=0)
            score = max(0, min(grading.MAX_SCORE, int(item.score)))
            items.append({"key": key, "score": score, "evidence": list(item.evidence)})
        fb = PracticeFeedback.objects.create(
            submission=sub,
            grader=getattr(grader, "name", type(grader).__name__),
            graded_at=timezone.now(),
            day=day,
            items=items,
        )
    # 저장한 값 그대로 돌려준다 — 뒤의 GET 과 같은 모양·같은 시각.
    fb.refresh_from_db()
    return _feedback_out(fb)


@practice_router.get("/practice/submissions/{submission_id}/feedback", response=FeedbackOut)
def get_feedback(request: HttpRequest, submission_id: int):
    sub = _my_practice_submission(request, submission_id)
    fb = PracticeFeedback.objects.filter(submission=sub).first()
    if fb is None:
        raise HttpError(404, "아직 피드백이 없습니다.")
    return _feedback_out(fb)


@practice_router.get("/practice/feedback-quota", response=FeedbackQuotaOut)
def feedback_quota(request: HttpRequest):
    used = _used(request.auth, _today())
    return FeedbackQuotaOut(limit=FEEDBACK_DAILY_LIMIT, used=used, remaining=max(0, FEEDBACK_DAILY_LIMIT - used))


# ---------- 내 기록 ----------


class PracticeScenarioOut(Schema):
    id: str
    title: str
    total: int
    best_passed: int | None
    submission_count: int
    last_submitted_at: datetime | None


class PracticeHistoryOut(Schema):
    id: int
    submitted_at: datetime
    passed: int
    total: int
    has_transcript: bool
    has_feedback: bool


class PracticeSubmissionOut(Schema):
    id: int
    scenario_id: str
    submitted_at: datetime
    passed: int
    total: int
    has_transcript: bool
    results: list[dict]
    feedback: FeedbackOut | None


def _my_practice_membership(request: HttpRequest) -> Membership:
    m = Membership.objects.filter(user=request.auth, cohort__kind=Cohort.Kind.PRACTICE).first()
    if m is None:
        raise HttpError(404, "연습을 시작하지 않았습니다.")
    return m


@practice_router.get("/practice/scenarios", response=list[PracticeScenarioOut])
def my_practice_scenarios(request: HttpRequest):
    m = _my_practice_membership(request)
    subs: dict[str, list[Submission]] = {}
    for sub in Submission.objects.filter(membership=m).order_by("id"):
        subs.setdefault(sub.scenario_id, []).append(sub)
    rows = []
    for sid, scenario in registry.all_scenarios().items():
        mine = subs.get(sid, [])
        rows.append(
            PracticeScenarioOut(
                id=sid,
                title=scenario.title,
                total=len(scenario.checks),
                best_passed=max((passed_against(s, scenario) for s in mine), default=None),
                submission_count=len(mine),
                last_submitted_at=max((s.submitted_at for s in mine), default=None),
            )
        )
    return rows


@practice_router.get("/practice/scenarios/{scenario_id}/submissions", response=list[PracticeHistoryOut])
def my_practice_history(request: HttpRequest, scenario_id: str):
    if registry.get(scenario_id) is None:
        raise HttpError(404, "시나리오를 찾을 수 없습니다.")
    m = _my_practice_membership(request)
    subs = Submission.objects.filter(membership=m, scenario_id=scenario_id).order_by("-id")
    with_feedback = set(PracticeFeedback.objects.filter(submission__in=subs).values_list("submission_id", flat=True))
    out = []
    for sub in subs:
        passed, total = score(sub)
        out.append(
            PracticeHistoryOut(
                id=sub.id,
                submitted_at=sub.submitted_at,
                passed=passed,
                total=total,
                has_transcript=has_transcript(sub),
                has_feedback=sub.id in with_feedback,
            )
        )
    return out


@practice_router.get("/practice/submissions/{submission_id}", response=PracticeSubmissionOut)
def my_practice_submission(request: HttpRequest, submission_id: int):
    sub = Submission.objects.filter(
        id=submission_id,
        membership__user=request.auth,
        membership__cohort__kind=Cohort.Kind.PRACTICE,
    ).first()
    if sub is None:
        raise HttpError(404, "연습 제출을 찾을 수 없습니다.")
    fb = PracticeFeedback.objects.filter(submission=sub).first()
    passed, total = score(sub)
    return PracticeSubmissionOut(
        id=sub.id,
        scenario_id=sub.scenario_id,
        submitted_at=sub.submitted_at,
        passed=passed,
        total=total,
        has_transcript=has_transcript(sub),
        results=sub.results,
        feedback=_feedback_out(fb) if fb else None,
    )
