"""e2e 전용 시계 당기기 — `python manage.py e2e_expire_exam <cohort_id>` (#194)."""

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "e2e 스택 전용: 그 시험 회차의 응시 중인 응시를 마감이 지난 꼴로 옮긴다."

    def add_arguments(self, parser):
        parser.add_argument("cohort_id", type=int)

    def handle(self, *args, **options):
        raise NotImplementedError("#194")
