"""개인 연습 API(/api/practice…) — 연습 묶음 참여(#132), 피드백(#134), 내 기록(#136).

연습 묶음의 시나리오 화면·환경 준비·제출은 기존 학생 경로(`/api/cohorts/<id>/…`)를 그대로 쓴다.
"""

from __future__ import annotations

from django.db import IntegrityError, transaction
from django.http import HttpRequest
from ninja import Router, Schema
from ninja.errors import HttpError

from accounts.auth import jwt_auth
from cohorts.models import Membership
from cohorts.schemas import JoinOut
from exams.api import HIDDEN_USER_PREFIX

from .services import practice_cohort

practice_router = Router(tags=["practice"], auth=jwt_auth)


# ---------- 연습 묶음 참여 ----------


class PracticeStatusOut(Schema):
    cohort_id: int
    name: str
    #: 내가 연습 묶음에 참여했는가(「연습 시작」을 눌렀는가).
    joined: bool


@practice_router.get("/practice", response=PracticeStatusOut)
def practice_status(request: HttpRequest):
    c = practice_cohort()
    joined = Membership.objects.filter(user=request.auth, cohort=c).exists()
    return PracticeStatusOut(cohort_id=c.id, name=c.name, joined=joined)


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


@practice_router.post("/practice/submissions/{submission_id}/feedback")
def request_feedback(request: HttpRequest, submission_id: int):
    raise NotImplementedError("#134")


@practice_router.get("/practice/submissions/{submission_id}/feedback")
def get_feedback(request: HttpRequest, submission_id: int):
    raise NotImplementedError("#134")


@practice_router.get("/practice/feedback-quota")
def feedback_quota(request: HttpRequest):
    raise NotImplementedError("#134")


# ---------- 내 기록 ----------


@practice_router.get("/practice/scenarios")
def my_practice_scenarios(request: HttpRequest):
    raise NotImplementedError("#136")


@practice_router.get("/practice/scenarios/{scenario_id}/submissions")
def my_practice_history(request: HttpRequest, scenario_id: str):
    raise NotImplementedError("#136")


@practice_router.get("/practice/submissions/{submission_id}")
def my_practice_submission(request: HttpRequest, submission_id: int):
    raise NotImplementedError("#136")
