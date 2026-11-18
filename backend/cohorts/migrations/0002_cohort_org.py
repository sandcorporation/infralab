"""조직 이전 1/3: 기수에 조직 FK 를 비어 있어도 되게 더한다."""

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("cohorts", "0001_initial"),
        ("orgs", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="cohort",
            name="org",
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="cohorts",
                to="orgs.organization",
            ),
        ),
    ]
