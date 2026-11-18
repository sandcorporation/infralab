"""조직(Organization)과 조직 담당자(OrgMember).

조직 → 묶음(`cohorts.Cohort`) → 응시자(`cohorts.Membership`). 강사 표면의 권한은 「이 묶음의 조직
담당자인가」로 판정한다(`orgs.services`). 역할 owner·staff 는 지금은 같은 권한이고, 담당자 관리 같은
owner 전용 동작은 다음 단계에서 붙는다.
"""

from __future__ import annotations

from django.conf import settings
from django.db import models

#: 이전(cohorts 0003) 이 만드는 조직, 그리고 `set_instructor` 가 강사를 넣는 조직의 이름.
DEFAULT_ORG_NAME = "기본 조직"


class Organization(models.Model):
    #: 관리 명령이 이름으로 조직을 찾으므로 유일하다.
    name = models.CharField(max_length=100, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:  # pragma: no cover
        return self.name


class OrgMember(models.Model):
    class Role(models.TextChoices):
        OWNER = "owner", "owner"
        STAFF = "staff", "staff"

    org = models.ForeignKey(Organization, related_name="members", on_delete=models.CASCADE)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, related_name="org_memberships", on_delete=models.CASCADE)
    role = models.CharField(max_length=16, choices=Role.choices, default=Role.STAFF)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["org", "user"], name="unique_org_member")]
        ordering = ["joined_at", "id"]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.user_id}@{self.org_id}:{self.role}"
