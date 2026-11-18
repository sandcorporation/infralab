"""인증 도메인 모델.

사용자는 sandcorp-auth 로그인으로만 들어온다 — 비밀번호 로그인 경로는 없다(`set_unusable_password`).
사람을 이메일로 찾지 않는다. auth 의 `sub` 가 바뀌지 않는 키이고, 사용자 이름은 `sandcorp:<sub>` 다.
"""

from __future__ import annotations

import secrets

from django.contrib.auth.models import AbstractUser
from django.db import IntegrityError, models, transaction


class User(AbstractUser):
    #: 옛 전역 강사 플래그. 권한 판정에는 더 이상 쓰지 않는다 — 강사 권한은 조직 역할(`orgs.OrgMember`)이다.
    #: 이전(cohorts 0003)이 이 값으로 「기본 조직」 owner 를 정했다. 지울지는 다음 티켓에서 정한다.
    is_instructor = models.BooleanField(default=False)
    #: 화면에 보이는 이름. auth ID 토큰의 `name` 을 로그인마다 최신값으로 받는다. 없으면 빈 문자열.
    display_name = models.CharField(max_length=100, blank=True)
    #: 학생 PC 의 에이전트가 요구하는 Bearer 토큰 — 사람 하나에 하나. 그 사용자의 모든 수업·연습 참여가 같은 토큰·같은
    #: compose.yml 을 쓴다(#153). 응시는 응시마다 숨은 사용자라 저절로 따로다. 처음 필요할 때 만든다(`agent_token_for`).
    agent_token = models.CharField(max_length=64, unique=True, null=True, blank=True, default=None)

    def __str__(self) -> str:  # pragma: no cover
        return self.username


class WebhookEvent(models.Model):
    """처리한 auth 웹훅 이벤트 id(W4). 재시도 기간(약 2일)보다 길게 — 7일 — 기억하고 그 뒤 지운다."""

    id = models.CharField(max_length=64, primary_key=True)
    received_at = models.DateTimeField(auto_now_add=True, db_index=True)

    def __str__(self) -> str:  # pragma: no cover
        return self.id


def _new_agent_token() -> str:
    return secrets.token_urlsafe(24)


def agent_token_for(user: User) -> str:
    """사용자의 에이전트 토큰. 없으면 만든다 — 동시에 두 요청이 와도 먼저 쓴 값 하나만 남는다."""

    if user.agent_token:
        return user.agent_token
    User.objects.filter(pk=user.pk, agent_token__isnull=True).update(agent_token=_new_agent_token())
    user.refresh_from_db(fields=["agent_token"])
    assert user.agent_token
    return user.agent_token


def regenerate_agent_token(user: User) -> str:
    """새 토큰으로 바꾼다. 옛 토큰을 박은 compose.yml 의 에이전트는 더 이상 화면과 맞지 않는다."""

    for attempt in range(3):
        token = _new_agent_token()
        try:
            with transaction.atomic():
                User.objects.filter(pk=user.pk).update(agent_token=token)
            break
        except IntegrityError:
            # 유일 제약 충돌은 천문학적으로 드물지만 500 대신 다시 뽑는다.
            if attempt == 2:
                raise
    user.agent_token = token
    return token
