"""에이전트 토큰을 참여에서 사용자로(#153).

사용자마다 참여 토큰 하나를 사용자 토큰으로 옮긴다 — 가장 최근에 쓴 참여의 것(제출·가입 중 늦은 시각). 학생 PC 에서
돌고 있는 compose.yml 은 대개 그 참여의 것이라 이전 뒤에도 끊기지 않는다. 참여가 없는 사용자는 처음 필요할 때 만든다
(`accounts.models.agent_token_for`). 참여 쪽 열은 그대로 둔다(옛 backend·롤백이 읽는다).
"""

from datetime import datetime

from django.db import migrations, models
from django.db.models import Max


def copy_latest_membership_token(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    Membership = apps.get_model("cohorts", "Membership")
    Submission = apps.get_model("submissions", "Submission")

    last_submitted = dict(
        Submission.objects.values("membership_id").annotate(t=Max("submitted_at")).values_list("membership_id", "t")
    )
    best: dict[int, tuple[datetime, int, str]] = {}
    for pk, user_id, token, joined_at in Membership.objects.values_list("pk", "user_id", "agent_token", "joined_at"):
        used = max(joined_at, last_submitted.get(pk) or joined_at)
        candidate = (used, pk, token)
        if user_id not in best or candidate > best[user_id]:
            best[user_id] = candidate
    for user_id, (_, _, token) in best.items():
        User.objects.filter(pk=user_id, agent_token__isnull=True).update(agent_token=token)


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0002_sandcorp_auth"),
        ("cohorts", "0007_practice_cohort"),
        ("submissions", "0002_submission_ai_transcript"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="agent_token",
            field=models.CharField(blank=True, default=None, max_length=64, null=True, unique=True),
        ),
        migrations.RunPython(copy_latest_membership_token, migrations.RunPython.noop),
    ]
