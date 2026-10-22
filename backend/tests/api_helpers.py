"""시험용 시나리오 헬퍼 — 사람(학생·강사)을 만들고 API 를 친다.

Fake 소셜 어댑터의 토큰 형식은 ``"<uid>:<email>[:<nickname>]"`` 이다.
"""

from __future__ import annotations

from dataclasses import dataclass

from django.core.management import call_command


@dataclass
class Session:
    access: str
    refresh: str

    @property
    def headers(self) -> dict[str, str]:
        return {"HTTP_AUTHORIZATION": f"Bearer {self.access}"}


class Api:
    def __init__(self, client) -> None:
        self.client = client

    # ---------- 인증 ----------

    def login(self, uid: str = "u1", email: str = "", nickname: str = "", provider: str = "kakao") -> Session:
        token = f"{uid}:{email or uid + '@example.com'}" + (f":{nickname}" if nickname else "")
        res = self.client.post(
            f"/api/auth/social/{provider}/login",
            data={"access_token": token},
            content_type="application/json",
        )
        assert res.status_code == 200, res.content
        body = res.json()
        return Session(access=body["access"], refresh=body["refresh"])

    def login_instructor(self, uid: str = "teacher") -> Session:
        session = self.login(uid)
        call_command("set_instructor", f"kakao:{uid}")
        return session

    # ---------- 요청 ----------

    def get(self, path: str, session: Session | None = None):
        return self.client.get(path, **(session.headers if session else {}))

    def post(self, path: str, data=None, session: Session | None = None):
        return self.client.post(
            path, data=data or {}, content_type="application/json", **(session.headers if session else {})
        )

    def put(self, path: str, data=None, session: Session | None = None):
        return self.client.put(
            path, data=data or {}, content_type="application/json", **(session.headers if session else {})
        )

    def patch(self, path: str, data=None, session: Session | None = None):
        return self.client.patch(
            path, data=data or {}, content_type="application/json", **(session.headers if session else {})
        )

    def delete(self, path: str, session: Session | None = None):
        return self.client.delete(path, **(session.headers if session else {}))

    def me(self, session: Session) -> dict:
        res = self.get("/api/accounts/me", session)
        assert res.status_code == 200, res.content
        return res.json()

    # ---------- 기수 ----------

    def create_cohort(self, instructor: Session, name: str = "1기") -> dict:
        res = self.post("/api/instructor/cohorts", {"name": name}, instructor)
        assert res.status_code == 201, res.content
        return res.json()

    def join(self, student: Session, token: str) -> dict:
        res = self.post(f"/api/join/{token}", session=student)
        assert res.status_code == 200, res.content
        return res.json()

    def open_scenarios(self, instructor: Session, cohort_id: int, scenario_ids: list[str]) -> list[str]:
        res = self.put(f"/api/instructor/cohorts/{cohort_id}/scenarios", {"scenario_ids": scenario_ids}, instructor)
        assert res.status_code == 200, res.content
        return res.json()
