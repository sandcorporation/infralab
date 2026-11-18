import psycopg
from django.db import connection
from django.http import HttpRequest
from ninja import NinjaAPI, Status

from accounts.api import instructor_router as accounts_instructor_router
from accounts.api import router as accounts_router
from cohorts.api import instructor_router as cohorts_instructor_router
from cohorts.api import join_router, student_router
from exams.api import exam_router, proxy_router
from exams.api import instructor_router as exams_instructor_router
from orgs.api import instructor_router as orgs_instructor_router
from orgs.api import invite_router
from scenarios.api import instructor_router as scenarios_instructor_router
from scenarios.api import student_router as scenarios_student_router
from submissions.api import student_router as submissions_student_router
from submissions.instructor_api import instructor_router as submissions_instructor_router

api = NinjaAPI(title="infralab API", version="0.1.0")

api.add_router("", accounts_router)
api.add_router("", join_router)
api.add_router("", invite_router)
api.add_router("", student_router)
api.add_router("", scenarios_student_router)
api.add_router("", submissions_student_router)
api.add_router("", exam_router)
api.add_router("", proxy_router)
# 강사 표면. 라우터 자체가 강사 플래그를 요구한다(accounts.auth.InstructorAuth).
api.add_router("/instructor", accounts_instructor_router)
api.add_router("/instructor", cohorts_instructor_router)
api.add_router("/instructor", orgs_instructor_router)
api.add_router("/instructor", scenarios_instructor_router)
api.add_router("/instructor", submissions_instructor_router)
api.add_router("/instructor", exams_instructor_router)


@api.get("/health", auth=None, response={200: dict[str, str], 503: dict[str, object]})
def health(request: HttpRequest) -> Status[dict[str, object]]:
    """운영 health(Gatus 외부 감시·Jenkins healthCmd·compose healthcheck 가 함께 쓴다).

    이 서비스가 기대는 것은 DB 하나다(redis·백그라운드 워커 없음 — 워커가 생기면 여기에 더하고
    준비 점검을 따로 나눈다). 점검마다 1초 제한, 실패하면 503 과 실패한 이름만 낸다(호스트·오류 원문 없음).
    """
    failed = [name for name, check in HEALTH_CHECKS if not check()]
    if failed:
        return Status(503, {"status": "error", "failed": failed})
    return Status(200, {"status": "ok"})


def _db_answers() -> bool:
    """새 연결로 SELECT 1 — 연결 1초·쿼리 1초 제한. Django 의 오래 쥔 연결과 따로 본다."""
    params = connection.get_connection_params()
    params.pop("cursor_factory", None)
    params.pop("context", None)
    try:
        with psycopg.connect(**params, connect_timeout=1, options="-c statement_timeout=1000") as conn:
            return conn.execute("SELECT 1").fetchone() == (1,)
    except Exception:  # noqa: BLE001 — 어떤 실패든 「db 실패」 하나로 보고한다
        return False


HEALTH_CHECKS = [("db", _db_answers)]
