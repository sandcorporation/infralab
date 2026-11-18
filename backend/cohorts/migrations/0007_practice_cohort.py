"""개인 연습 데이터 이전: 「개인 연습」 조직(담당자 없음)과 그 안의 연습 묶음 하나를 만든다(#132).

이미 있으면 새로 만들지 않는다 — 연습 묶음은 언제나 하나다. 되돌리기는 이 이전이 만든 연습 묶음과 (다른 묶음이
남지 않았으면) 조직을 지운다. 연습 묶음의 참여·제출도 함께 사라진다(참여는 CASCADE).
"""

from django.db import migrations

PRACTICE_ORG_NAME = "개인 연습"
PRACTICE_COHORT_NAME = "개인 연습"


def forwards(apps, schema_editor):
    Cohort = apps.get_model("cohorts", "Cohort")
    Organization = apps.get_model("orgs", "Organization")

    org, _ = Organization.objects.get_or_create(name=PRACTICE_ORG_NAME)
    if not Cohort.objects.filter(kind="practice").exists():
        Cohort.objects.create(org=org, name=PRACTICE_COHORT_NAME, kind="practice", join_open=False)


def backwards(apps, schema_editor):
    Cohort = apps.get_model("cohorts", "Cohort")
    Organization = apps.get_model("orgs", "Organization")

    Cohort.objects.filter(kind="practice").delete()
    org = Organization.objects.filter(name=PRACTICE_ORG_NAME).first()
    if org is not None and not Cohort.objects.filter(org=org).exists():
        org.delete()


class Migration(migrations.Migration):

    dependencies = [
        ("cohorts", "0006_alter_cohort_kind"),
        ("orgs", "0002_orginvite"),
    ]

    operations = [migrations.RunPython(forwards, backwards)]
