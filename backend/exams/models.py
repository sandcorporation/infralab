"""시험 모드 — 응시 링크(ExamInvite), 임시 토큰(AIToken), 프록시 기록(AIExchange).

응시 링크는 시험 회차(`cohorts.Cohort`, 종류 `exam`)의 지원자 한 사람의 응시 한 번이다(#70). 응시 흐름
필드(`membership`·`consented_at`·`started_at`·`finished_at`)는 #71, 임시 토큰과 프록시 기록은 #72 가 쓴다.
"""

from __future__ import annotations

from django.db import models
from django.utils import timezone

from cohorts.models import new_token


class ExamInvite(models.Model):
    cohort = models.ForeignKey("cohorts.Cohort", related_name="exam_invites", on_delete=models.CASCADE)
    #: 지원자 표시 이름(담당자의 메모).
    label = models.CharField(max_length=100)
    token = models.CharField(max_length=64, unique=True, default=new_token)
    created_at = models.DateTimeField(auto_now_add=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    membership = models.OneToOneField(
        "cohorts.Membership", related_name="exam_invite", null=True, blank=True, on_delete=models.SET_NULL
    )
    consented_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    #: 마감 뒤 지원자 화면이 올린 숨은 검사 결과 — {시나리오 id: [{check_id, pass, …}]}. 올라오기 전엔 null(#74).
    final_results = models.JSONField(null=True, blank=True, default=None)
    final_results_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.label}@{self.cohort_id}"


class AIToken(models.Model):
    """응시 한 번짜리 임시 토큰. 진짜 공급사 키가 아니다 — AI 프록시가 backend 에 물어 확인한다(#72)."""

    invite = models.OneToOneField(ExamInvite, related_name="ai_token", on_delete=models.CASCADE)
    token = models.CharField(max_length=64, unique=True, default=new_token)
    issued_at = models.DateTimeField(auto_now_add=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    used_tokens = models.IntegerField(default=0)
    last_client_id = models.CharField(max_length=200, blank=True, default="")
    last_used_at = models.DateTimeField(null=True, blank=True)


class AIExchange(models.Model):
    """AI 프록시가 넘긴 요청·응답 한 번(채점 재료)."""

    ai_token = models.ForeignKey(AIToken, related_name="exchanges", on_delete=models.CASCADE)
    tool = models.CharField(max_length=20)
    model = models.CharField(max_length=200, blank=True, default="")
    client_id = models.CharField(max_length=200, blank=True, default="")
    request = models.TextField(blank=True, default="")
    response = models.TextField(blank=True, default="")
    input_tokens = models.IntegerField(default=0)
    output_tokens = models.IntegerField(default=0)
    # 캐시 읽기·쓰기 입력 토큰(input_tokens 에 이미 들어 있다). 응답에 필드가 없거나 #252 전 기록이면 null.
    cache_read_input_tokens = models.IntegerField(null=True, blank=True)
    cache_creation_input_tokens = models.IntegerField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]


class ExamEvent(models.Model):
    """감독 신호 한 건 — 지원자 화면이 보낸 탭 이탈·포커스 잃음·붙여넣기와 서버가 남기는 프록시 밖 AI 사용(#75)."""

    invite = models.ForeignKey(ExamInvite, related_name="events", on_delete=models.CASCADE)
    kind = models.CharField(max_length=30)
    detail = models.TextField(blank=True, default="")
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["at", "id"]


class ExamRubric(models.Model):
    """응시 한 번의 LLM 루브릭(#76). 다시 채점하면 덮어쓴다 — 담당자 수정 이력(`RubricEdit`)은 남는다.

    `items` 는 [{key, score, llm_score, evidence, edited}] — `llm_score` 는 채점기가 준 원래 점수,
    `score` 는 담당자 수정을 반영한 지금 점수.
    """

    invite = models.OneToOneField(ExamInvite, related_name="rubric", on_delete=models.CASCADE)
    grader = models.CharField(max_length=30)
    graded_at = models.DateTimeField()
    items = models.JSONField(default=list)


class RubricEdit(models.Model):
    """담당자의 루브릭 점수 수정 한 번(#76). 다시 채점해도 지우지 않는다."""

    invite = models.ForeignKey(ExamInvite, related_name="rubric_edits", on_delete=models.CASCADE)
    key = models.CharField(max_length=40)
    from_score = models.IntegerField()
    to_score = models.IntegerField()
    reason = models.TextField()
    #: 고친 담당자의 표시 이름(그때의 것).
    by = models.CharField(max_length=150)
    at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["at", "id"]


class LLMUsage(models.Model):
    """backend 가 직접 부른 Claude 호출 한 번의 사용량(#249) — 채점·연습 피드백의 원가 재료.

    덮어쓰지 않고 쌓는다(다시 채점하면 행이 늘어난다). 요청·응답 본문이나 개인정보는 넣지 않는다.
    `invite` 는 채점한 응시, `submission` 은 피드백을 받은 연습 제출 — 대상이 지워져도 사용량은 남는다.
    """

    PURPOSE_GRADING = "grading"
    PURPOSE_PRACTICE_FEEDBACK = "practice_feedback"
    PURPOSES = [(PURPOSE_GRADING, "채점"), (PURPOSE_PRACTICE_FEEDBACK, "연습 피드백")]

    purpose = models.CharField(max_length=30, choices=PURPOSES)
    model = models.CharField(max_length=200, blank=True, default="")
    input_tokens = models.IntegerField(default=0)
    output_tokens = models.IntegerField(default=0)
    cache_read_input_tokens = models.IntegerField(default=0)
    cache_creation_input_tokens = models.IntegerField(default=0)
    invite = models.ForeignKey(
        ExamInvite, related_name="llm_usages", null=True, blank=True, on_delete=models.SET_NULL
    )
    submission = models.ForeignKey(
        "submissions.Submission", related_name="llm_usages", null=True, blank=True, on_delete=models.SET_NULL
    )
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["created_at", "id"]
        indexes = [models.Index(fields=["created_at"])]

    def __str__(self) -> str:  # pragma: no cover
        return f"{self.purpose} {self.model} in={self.input_tokens} out={self.output_tokens}"
