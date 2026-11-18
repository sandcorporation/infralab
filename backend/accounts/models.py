"""인증 도메인 모델.

사용자는 sandcorp-auth 로그인으로만 들어온다 — 비밀번호 로그인 경로는 없다(`set_unusable_password`).
사람을 이메일로 찾지 않는다. auth 의 `sub` 가 바뀌지 않는 키이고, 사용자 이름은 `sandcorp:<sub>` 다.
"""

from __future__ import annotations

from django.contrib.auth.models import AbstractUser
from django.db import models


class User(AbstractUser):
    #: 옛 전역 강사 플래그. 권한 판정에는 더 이상 쓰지 않는다 — 강사 권한은 조직 역할(`orgs.OrgMember`)이다.
    #: 이전(cohorts 0003)이 이 값으로 「기본 조직」 owner 를 정했다. 지울지는 다음 티켓에서 정한다.
    is_instructor = models.BooleanField(default=False)
    #: 화면에 보이는 이름. auth ID 토큰의 `name` 을 로그인마다 최신값으로 받는다. 없으면 빈 문자열.
    display_name = models.CharField(max_length=100, blank=True)

    def __str__(self) -> str:  # pragma: no cover
        return self.username


class WebhookEvent(models.Model):
    """처리한 auth 웹훅 이벤트 id(W4). 재시도 기간(약 2일)보다 길게 — 7일 — 기억하고 그 뒤 지운다."""

    id = models.CharField(max_length=64, primary_key=True)
    received_at = models.DateTimeField(auto_now_add=True, db_index=True)

    def __str__(self) -> str:  # pragma: no cover
        return self.id
