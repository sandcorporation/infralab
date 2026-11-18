"""연습 묶음 찾기 — 시스템에 하나뿐인 「연습」 종류 묶음과 그 조직(「개인 연습」, 담당자 없음).

데이터 이전(cohorts 0007)이 만들지만, 시험 DB 비우기처럼 사라졌으면 처음 찾을 때 다시 만든다.
"""

from __future__ import annotations

from django.db import transaction

from cohorts.models import Cohort
from orgs.models import Organization

#: 데이터 이전(cohorts 0007)과 같은 이름.
PRACTICE_ORG_NAME = "개인 연습"
PRACTICE_COHORT_NAME = "개인 연습"


def practice_cohort() -> Cohort:
    """연습 묶음. 없으면 만든다 — 동시에 불려도 하나만 생기게 조직 행을 잠그고 본다."""

    existing = Cohort.objects.filter(kind=Cohort.Kind.PRACTICE).order_by("id").first()
    if existing is not None:
        return existing
    with transaction.atomic():
        org, _ = Organization.objects.get_or_create(name=PRACTICE_ORG_NAME)
        Organization.objects.select_for_update().get(pk=org.pk)
        cohort = Cohort.objects.filter(kind=Cohort.Kind.PRACTICE).order_by("id").first()
        if cohort is None:
            cohort = Cohort.objects.create(
                org=org, name=PRACTICE_COHORT_NAME, kind=Cohort.Kind.PRACTICE, join_open=False
            )
    return cohort
