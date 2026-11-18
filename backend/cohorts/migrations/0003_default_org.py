"""조직 이전 2/3: 「기본 조직」을 만들어 조직 없는 기수 전부와 `is_instructor=True` 사용자 전부(owner)를 넣는다.

옮길 것이 하나도 없으면(새 DB) 조직을 만들지 않는다. 기수의 가입 링크·참여(에이전트 토큰)·제출은
행을 건드리지 않으므로 그대로 유효하다. 되돌리기는 아무것도 하지 않는다 — 0002 를 되돌리면 FK 열이
통째로 사라진다.
"""

from django.db import migrations

DEFAULT_ORG_NAME = "기본 조직"


def forwards(apps, schema_editor):
    Cohort = apps.get_model("cohorts", "Cohort")
    Organization = apps.get_model("orgs", "Organization")
    OrgMember = apps.get_model("orgs", "OrgMember")
    User = apps.get_model("accounts", "User")

    orphans = Cohort.objects.filter(org__isnull=True)
    instructors = User.objects.filter(is_instructor=True)
    if not orphans.exists() and not instructors.exists():
        return
    org, _ = Organization.objects.get_or_create(name=DEFAULT_ORG_NAME)
    orphans.update(org=org)
    for user in instructors:
        OrgMember.objects.update_or_create(org=org, user=user, defaults={"role": "owner"})


class Migration(migrations.Migration):

    dependencies = [
        ("cohorts", "0002_cohort_org"),
        ("accounts", "0001_initial"),
    ]

    operations = [migrations.RunPython(forwards, migrations.RunPython.noop)]
