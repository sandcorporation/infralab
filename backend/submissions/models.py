"""제출(Submission) — 학생 PC 의 에이전트가 낸 채점 결과를 브라우저가 서버에 올린 것.

수업 보조용이다. 위조를 막지 않되 증거(검사별 원시 출력)가 남게 해 강사가 「왜 틀렸는지」를 본다.
이력은 모두 남기고 격자는 최신 것을 본다.
"""

from __future__ import annotations

from django.db import models

from cohorts.models import Membership

#: 검사 하나의 원시 출력 상한(문자). 에이전트도 8KiB 에서 자르지만 서버가 다시 한 번 지킨다.
MAX_OUTPUT_CHARS = 4000


class Submission(models.Model):
    membership = models.ForeignKey(Membership, related_name="submissions", on_delete=models.CASCADE)
    scenario_id = models.CharField(max_length=64)
    submitted_at = models.DateTimeField(auto_now_add=True)
    agent_version = models.CharField(max_length=64, blank=True)
    passed = models.PositiveIntegerField()
    total = models.PositiveIntegerField()
    #: [{check_id, name, pass, output, truncated, exit_code, error}] — 검사 정의 순서.
    results = models.JSONField()

    class Meta:
        # 「최신」은 어디서나 id 가 큰 것 — services.latest_submissions_by_scenario 와 같은 기준.
        ordering = ["-id"]
        indexes = [models.Index(fields=["membership", "scenario_id", "-id"])]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.membership_id}/{self.scenario_id} {self.passed}/{self.total}"
