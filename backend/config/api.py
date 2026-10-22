from ninja import NinjaAPI

from accounts.api import instructor_router as accounts_instructor_router
from accounts.api import router as accounts_router
from cohorts.api import instructor_router as cohorts_instructor_router
from cohorts.api import join_router, student_router

api = NinjaAPI(title="infralab API", version="0.1.0")

api.add_router("", accounts_router)
api.add_router("", join_router)
api.add_router("", student_router)
# 강사 표면. 라우터 자체가 강사 플래그를 요구한다(accounts.auth.InstructorAuth).
api.add_router("/instructor", accounts_instructor_router)
api.add_router("/instructor", cohorts_instructor_router)


@api.get("/health", auth=None)
def health(request):
    return {"status": "ok"}
