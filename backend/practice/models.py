"""연습 피드백(#134) — 연습 제출 하나의 루브릭 채점 결과. 제출 하나에 하나, 고치지 않는다."""

from __future__ import annotations

from django.db import models

from submissions.models import Submission


class PracticeFeedback(models.Model):
    """「피드백 받기」로 만든 루브릭 피드백. `items` 는 [{key, score, evidence}] — 루브릭 순서.

    `day` 는 채점한 날(Asia/Seoul) — 사용자당 하루 한도를 이것으로 센다(사용자는 제출의 참여를 거쳐 간다 — 계정 합치기에서 제출과 함께 옮겨진다). 실패한 채점은 행을 만들지 않으므로 세지 않는다.
    """

    submission = models.OneToOneField(Submission, related_name="practice_feedback", on_delete=models.CASCADE)
    grader = models.CharField(max_length=30)
    graded_at = models.DateTimeField()
    day = models.DateField()
    items = models.JSONField(default=list)

    class Meta:
        indexes = [models.Index(fields=["day"])]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.submission_id} {self.grader} {self.day}"
