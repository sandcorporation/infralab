"""기수(Cohort)와 참여(Membership).

강사는 한 명이라 기수에 소유자가 없다. 가입 링크는 기수의 `join_token` 하나로, 재발급하면 옛 링크는
바로 죽는다. 참여는 사용자 × 기수 하나이고 학생별 에이전트 토큰을 든다(compose.yml 에 박힌다).
"""

from __future__ import annotations

import secrets

from django.conf import settings
from django.db import models


def new_token() -> str:
    return secrets.token_urlsafe(24)


class Cohort(models.Model):
    name = models.CharField(max_length=100)
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
    #: 학생 PC 의 에이전트가 요구하는 Bearer 토큰. 재발급 가능.
    agent_token = models.CharField(max_length=64, unique=True, default=new_token)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "cohort"], name="unique_membership")]
        ordering = ["joined_at"]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.user_id}@{self.cohort_id}"
