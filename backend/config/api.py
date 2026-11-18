from django.db import DatabaseError, connection
from django.http import HttpRequest
from ninja import NinjaAPI, Status

from accounts.api import instructor_router as accounts_instructor_router
from accounts.api import router as accounts_router
from cohorts.api import instructor_router as cohorts_instructor_router
from cohorts.api import join_router, student_router
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
# 강사 표면. 라우터 자체가 강사 플래그를 요구한다(accounts.auth.InstructorAuth).
api.add_router("/instructor", accounts_instructor_router)
api.add_router("/instructor", cohorts_instructor_router)
api.add_router("/instructor", orgs_instructor_router)
api.add_router("/instructor", scenarios_instructor_router)
api.add_router("/instructor", submissions_instructor_router)


@api.get("/health", auth=None, response={200: dict[str, str], 503: dict[str, str]})
def health(request: HttpRequest) -> Status[dict[str, str]]:
    """배포 헬스 확인(Jenkins healthCmd·compose healthcheck). DB 에 한 번 다녀와야 200 이다."""
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except DatabaseError:
        return Status(503, {"status": "error", "db": "unreachable"})
    return Status(200, {"status": "ok", "db": "ok"})
