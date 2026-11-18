"""기수(Cohort)와 참여(Membership).

조직 → 묶음 → 응시자: 기수(`Cohort`)는 수업 묶음이고 반드시 한 조직(`orgs.Organization`)에 속한다.
강사 표면은 그 조직의 담당자만 쓴다(`orgs.services`). 참여(`Membership`)가 응시자다. 가입 링크는 기수의 `join_token` 하나로, 재발급하면 옛 링크는
바로 죽는다. 참여는 사용자 × 기수 하나다. 에이전트 토큰은 참여가 아니라 사용자(`accounts.User.agent_token`) 것이다(#153).
"""

from __future__ import annotations

import secrets

from django.conf import settings
from django.db import models


def new_token() -> str:
    return secrets.token_urlsafe(24)


class Cohort(models.Model):
    class Kind(models.TextChoices):
        CLASS = "class", "수업"
        EXAM = "exam", "시험"
        PRACTICE = "practice", "연습"

    org = models.ForeignKey("orgs.Organization", related_name="cohorts", on_delete=models.PROTECT)
    name = models.CharField(max_length=100)
    #: 묶음의 종류. 수업이면 「기수」, 시험이면 「시험 회차」로 보인다.
    kind = models.CharField(max_length=10, choices=Kind.choices, default=Kind.CLASS)
    #: 시험 설정(시간 제한·감독·AI 키 지급·숨은 검사 …). 키는 2단계에서 정한다.
    exam_settings = models.JSONField(default=dict, blank=True)
    join_token = models.CharField(max_length=64, unique=True, default=new_token)
    join_open = models.BooleanField(default=True)
    archived = models.BooleanField(default=False)
    #: 이 기수에 열어 둔 시나리오 id 목록(저장소 scenarios/<id>). 순서가 화면 순서다.
    open_scenario_ids = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["archived", "-created_at"]

    def __str__(self) -> str:  # pragma: no cover
        return self.name


class Membership(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, related_name="memberships", on_delete=models.CASCADE)
    cohort = models.ForeignKey(Cohort, related_name="memberships", on_delete=models.CASCADE)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "cohort"], name="unique_membership")]
        ordering = ["joined_at"]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.user_id}@{self.cohort_id}"
