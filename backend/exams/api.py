"""시험 모드 API.

- 강사(/api/instructor/…): 시험 설정(#70), 응시 링크(#70), 임시 토큰 회수(#72), 점수(#74), 감독 기록(#75),
  보고서(#76), 시험 대시보드(#77) — 내가 담당자인 조직의 시험 회차만
- 지원자(/api/exam/{token}…): 응시 상태·enter·start·finish(#71), AI 키 설정(#72), 숨은 검사(#74), 감독 신호(#75)
- AI 프록시 전용(/api/proxy/…): 임시 토큰 확인·기록(#72), 공유 비밀 `EXAM_PROXY_SECRET`
"""

from __future__ import annotations

from django.http import HttpRequest
from ninja import Router

from accounts.auth import instructor_auth

instructor_router = Router(tags=["instructor"], auth=instructor_auth)
exam_router = Router(tags=["exam"])
proxy_router = Router(tags=["proxy"])


# ---------- 강사 ----------


@instructor_router.put("/cohorts/{cohort_id}/exam-settings")
def put_exam_settings(request: HttpRequest, cohort_id: int):
    raise NotImplementedError("#70")


@instructor_router.post("/cohorts/{cohort_id}/exam-invites")
def create_exam_invite(request: HttpRequest, cohort_id: int):
    raise NotImplementedError("#70")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites")
def list_exam_invites(request: HttpRequest, cohort_id: int):
    raise NotImplementedError("#70")


@instructor_router.delete("/cohorts/{cohort_id}/exam-invites/{invite_id}")
def revoke_exam_invite(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#70")


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/ai-token/revoke")
def revoke_ai_token(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#72")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/score")
def exam_score(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#74")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/events")
def exam_events(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#75")


@instructor_router.get("/cohorts/{cohort_id}/exam-invites/{invite_id}/report")
def exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#76")


@instructor_router.post("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/grade")
def grade_exam_report(request: HttpRequest, cohort_id: int, invite_id: int):
    raise NotImplementedError("#76")


@instructor_router.patch("/cohorts/{cohort_id}/exam-invites/{invite_id}/report/rubric/{key}")
def edit_rubric_item(request: HttpRequest, cohort_id: int, invite_id: int, key: str):
    raise NotImplementedError("#76")


@instructor_router.get("/exam-dashboard")
def exam_dashboard(request: HttpRequest):
    raise NotImplementedError("#77")


# ---------- 지원자 ----------


@exam_router.get("/exam/{token}", auth=None)
def exam_status(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/enter", auth=None)
def enter_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/start", auth=None)
def start_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.post("/exam/{token}/finish", auth=None)
def finish_exam(request: HttpRequest, token: str):
    raise NotImplementedError("#71")


@exam_router.get("/exam/{token}/ai-config", auth=None)
def exam_ai_config(request: HttpRequest, token: str):
    raise NotImplementedError("#72")


@exam_router.get("/exam/{token}/final-checks", auth=None)
def exam_final_checks(request: HttpRequest, token: str):
    raise NotImplementedError("#74")


@exam_router.post("/exam/{token}/final-results", auth=None)
def exam_final_results(request: HttpRequest, token: str):
    raise NotImplementedError("#74")


@exam_router.post("/exam/{token}/events", auth=None)
def exam_event(request: HttpRequest, token: str):
    raise NotImplementedError("#75")


# ---------- AI 프록시 전용 ----------


@proxy_router.post("/proxy/authorize", auth=None)
def proxy_authorize(request: HttpRequest):
    raise NotImplementedError("#72")


@proxy_router.post("/proxy/exchanges", auth=None)
def proxy_exchanges(request: HttpRequest):
    raise NotImplementedError("#72")
