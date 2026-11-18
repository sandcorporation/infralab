"""조직 이전 3/3: 모든 기수가 조직을 가졌으니 FK 를 필수로."""

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("cohorts", "0003_default_org"),
    ]

    operations = [
        migrations.AlterField(
            model_name="cohort",
            name="org",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.PROTECT, related_name="cohorts", to="orgs.organization"
            ),
        ),
    ]
