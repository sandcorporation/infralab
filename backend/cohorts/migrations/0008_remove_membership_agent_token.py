"""참여별 에이전트 토큰 열 지우기(#160). 토큰은 사용자 것이 됐고(#153) 이 열은 더 읽히지 않는다."""

from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ("cohorts", "0007_practice_cohort"),
        # 사용자 토큰으로 옮겨 담는 이전(accounts 0003)이 이 열을 읽으므로 그 뒤에 지운다.
        ("accounts", "0003_user_agent_token"),
    ]

    operations = [
        migrations.RemoveField(model_name="membership", name="agent_token"),
    ]
