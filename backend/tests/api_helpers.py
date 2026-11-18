"""시험용 시나리오 헬퍼 — 사람(학생·강사)을 만들고 API 를 친다.

로그인은 개발용 `POST /api/auth/dev-login`(사용자 이름 `sandcorp:<uid>`)으로 Django 세션을 연다. 사람마다
쿠키 항아리가 따로 있어야 하므로 `Session` 이 자기 테스트 클라이언트를 갖는다. 상태를 바꾸는 요청에는 브라우저처럼
대시보드 `Origin` 을 붙인다(세션 인증의 CSRF 확인).
"""

from __future__ import annotations

from dataclasses import dataclass

from django.conf import settings
from django.core.management import call_command
from django.test import Client

from orgs.models import DEFAULT_ORG_NAME, Organization


def dashboard_origin() -> str:
    return settings.DASHBOARD_ORIGINS[0]


@dataclass
class Session:
    client: Client
    username: str


class Api:
    def __init__(self, client) -> None:
        self.client = client

    # ---------- 인증 ----------

    def login(self, uid: str = "u1", nickname: str = "") -> Session:
        client = Client()
        res = client.post(
            "/api/auth/dev-login",
            data={"uid": uid, "nickname": nickname},
            content_type="application/json",
        )
        assert res.status_code == 204, res.content
        return Session(client=client, username=f"sandcorp:{uid}")

    def login_instructor(self, uid: str = "teacher", org: str = DEFAULT_ORG_NAME, role: str = "owner") -> Session:
        """조직 `org`(없으면 만든다)의 담당자로 로그인한다. 기본은 옛 강사 자리인 「기본 조직」의 owner."""

        session = self.login(uid)
        if Organization.objects.filter(name=org).exists():
            call_command("add_org_member", org, session.username, "--role", role)
        else:
            call_command("create_org", org, "--owner", session.username)
            if role != "owner":
                call_command("add_org_member", org, session.username, "--role", role)
        return session

    # ---------- 요청 ----------

    def _client(self, session: Session | None) -> Client:
        return session.client if session else self.client

    def get(self, path: str, session: Session | None = None):
        return self._client(session).get(path)

    def post(self, path: str, data=None, session: Session | None = None):
        return self._client(session).post(
            path, data=data or {}, content_type="application/json", HTTP_ORIGIN=dashboard_origin()
        )

    def put(self, path: str, data=None, session: Session | None = None):
        return self._client(session).put(
            path, data=data or {}, content_type="application/json", HTTP_ORIGIN=dashboard_origin()
        )

    def patch(self, path: str, data=None, session: Session | None = None):
        return self._client(session).patch(
            path, data=data or {}, content_type="application/json", HTTP_ORIGIN=dashboard_origin()
        )

    def delete(self, path: str, session: Session | None = None):
        return self._client(session).delete(path, HTTP_ORIGIN=dashboard_origin())

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

    def submit(self, student: Session, cohort_id: int, scenario_id: str, results: list[dict], agent_version: str = "0.2.0"):
        return self.post(
            f"/api/cohorts/{cohort_id}/scenarios/{scenario_id}/submissions",
            {"agent_version": agent_version, "results": results},
            student,
        )


# ---------- s3-static-site 시나리오의 가짜 에이전트 결과 ----------

S3 = "s3-static-site"
S3_CHECK_IDS = ["bucket-exists", "versioning-enabled", "index-uploaded", "website-configured"]


def s3_results(passing: set[str], output: str = "ok") -> list[dict]:
    """에이전트 /api/check 응답의 results[] 모양. `passing` 에 든 검사만 통과."""

    return [
        {
            "id": cid,
            "name": cid,
            "pass": cid in passing,
            "output": output if cid in passing else "An error occurred (404)",
            "exit_code": 0 if cid in passing else 254,
        }
        for cid in S3_CHECK_IDS
    ]
