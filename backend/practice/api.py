"""개인 연습 API(/api/practice…) — 연습 묶음 참여(#132), 피드백(#134), 내 기록(#136).

연습 묶음의 시나리오 화면·환경 준비·제출은 기존 학생 경로(`/api/cohorts/<id>/…`)를 그대로 쓴다.
"""

from __future__ import annotations

from django.http import HttpRequest
from ninja import Router

from accounts.auth import jwt_auth

practice_router = Router(tags=["practice"], auth=jwt_auth)


# ---------- 연습 묶음 참여 ----------


@practice_router.get("/practice")
def practice_status(request: HttpRequest):
    raise NotImplementedError("#132")


@practice_router.post("/practice/join")
def join_practice(request: HttpRequest):
    raise NotImplementedError("#132")


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
