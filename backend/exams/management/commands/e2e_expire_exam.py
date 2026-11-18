"""e2e 전용 시계 당기기 — `python manage.py e2e_expire_exam <cohort_id>` (#194)."""

from datetime import timedelta

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from cohorts.models import Cohort
from exams.models import ExamInvite


class Command(BaseCommand):
    help = "e2e 스택 전용: 그 시험 회차의 응시 중인 응시를 마감이 지난 꼴로 옮긴다."

    def add_arguments(self, parser):
        parser.add_argument("cohort_id", type=int)

    def handle(self, *args, **options):
        if not settings.E2E_HOOKS_ENABLED:
            raise CommandError("e2e 시계 당기기는 꺼져 있습니다 — DEBUG 에서 INFRALAB_E2E_HOOKS=1 일 때만 켜집니다.")
        cohort = Cohort.objects.filter(pk=options["cohort_id"], kind=Cohort.Kind.EXAM).first()
        if cohort is None:
            raise CommandError(f"시험 회차 {options['cohort_id']} 이(가) 없습니다.")
        minutes = int((cohort.exam_settings or {}).get("time_limit_minutes", 0))
        shift = timedelta(minutes=minutes, seconds=1)
        invites = ExamInvite.objects.filter(cohort=cohort, started_at__isnull=False, finished_at__isnull=True)
        count = 0
        for invite in invites:
            invite.started_at -= shift
            invite.save(update_fields=["started_at"])
            count += 1
        self.stdout.write(f"{count}건을 마감이 지난 꼴로 옮겼습니다.")
