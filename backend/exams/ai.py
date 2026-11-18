"""임시 토큰(AIToken) — 지원자에게 줄 AI 키 설정과 AI 프록시가 묻는 판정(#72).

진짜 공급사 키는 backend 에 없다. 지원자는 응시 한 번짜리 임시 토큰과 AI 프록시 주소를 받고, 프록시는
요청마다 `verdict` 로 허용 여부와 고정 모델을 묻고, 주고받은 내용과 사용량을 `record_exchange` 로 넘긴다.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from django.conf import settings
from django.db import transaction
from django.db.models import F
from django.utils import timezone

from . import services
from .models import AIExchange, AIToken, ExamInvite

#: 마지막 사용 뒤 이 시간 안에는 다른 클라이언트가 같은 토큰을 쓸 수 없다.
IN_USE_WINDOW = timedelta(minutes=5)
#: AI 프록시 안에서 공급사별 경로. 프록시(다음 티켓)가 이 경로로 받는다.
ANTHROPIC_PATH = "/anthropic"
OPENAI_PATH = "/openai/v1"
#: Codex 가 임시 토큰을 읽는 환경변수 이름(config.toml 의 env_key).
CODEX_TOKEN_ENV = "INFRALAB_AI_TOKEN"
#: AI 키 설정을 주는 도구 순서(로컬 LLM 은 agent 가 중계하므로 여기서 주지 않는다).
PROXY_TOOLS = ("claude_code", "codex")


def proxy_url() -> str:
    return settings.EXAM_PROXY_URL.rstrip("/")


def issue(invite: ExamInvite) -> AIToken:
    """응시의 임시 토큰. 처음 부르면 만들고, 다시 부르면 같은 토큰이다."""

    token, _ = AIToken.objects.get_or_create(invite=invite)
    return token


def revoke(invite: ExamInvite, now: datetime | None = None) -> None:
    """응시의 임시 토큰을 회수한다. 아직 없으면 회수된 채로 만들어 두어 뒤에 새로 발급되지 않게 한다."""

    now = now or timezone.now()
    token, created = AIToken.objects.get_or_create(invite=invite, defaults={"revoked_at": now})
    if not created and token.revoked_at is None:
        AIToken.objects.filter(pk=token.pk, revoked_at=None).update(revoked_at=now)


def tool_configs(invite: ExamInvite, token: str) -> list[dict]:
    """회차가 허용한 도구마다 workstation 터미널에 붙여 넣을 설정."""

    exam = invite.cohort.exam_settings or {}
    allowed = set(exam.get("tools", []))
    models = exam.get("models", {})
    base = proxy_url()
    out = []
    for tool in PROXY_TOOLS:
        if tool not in allowed:
            continue
        model = str(models.get(tool, ""))
        if tool == "claude_code":
            env = {
                "ANTHROPIC_BASE_URL": f"{base}{ANTHROPIC_PATH}",
                "ANTHROPIC_AUTH_TOKEN": token,
                "ANTHROPIC_MODEL": model,
            }
            out.append({"tool": tool, "model": model, "env": env, "config_toml": ""})
        else:
            out.append({"tool": tool, "model": model, "env": {CODEX_TOKEN_ENV: token}, "config_toml": _codex_toml(base, model)})
    return out


def _toml_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _codex_toml(base: str, model: str) -> str:
    return "\n".join(
        [
            f"model = {_toml_str(model)}",
            'model_provider = "infralab"',
            "",
            "[model_providers.infralab]",
            'name = "infralab AI 프록시"',
            f"base_url = {_toml_str(base + OPENAI_PATH)}",
            f"env_key = {_toml_str(CODEX_TOKEN_ENV)}",
            'wire_api = "responses"',
            "",
        ]
    )


@dataclass
class Verdict:
    allowed: bool
    reason: str | None = None
    model: str | None = None
    remaining_tokens: int | None = None


def _remaining(limit: int, used: int) -> int | None:
    """한도 0 은 한도 없음(None)."""

    return None if limit <= 0 else max(0, limit - used)


def verdict(token: str, tool: str, client_id: str) -> Verdict:
    """AI 프록시의 요청 하나를 허용할지. 허용하면 이 클라이언트가 토큰을 쓰는 중으로 적는다."""

    now = timezone.now()
    with transaction.atomic():
        ai = (
            AIToken.objects.select_for_update(of=("self",))
            .select_related("invite", "invite__cohort")
            .filter(token=token)
            .first()
        )
        if ai is None:
            return Verdict(False, "unknown")
        invite = ai.invite
        if ai.revoked_at is not None or invite.revoked_at is not None or invite.finished_at is not None:
            return Verdict(False, "revoked")
        if invite.started_at is None or services.ended_at(invite, now) is not None:
            return Verdict(False, "outside_window")
        exam = invite.cohort.exam_settings or {}
        if tool not in PROXY_TOOLS or tool not in exam.get("tools", []):
            return Verdict(False, "tool_not_allowed")
        remaining = _remaining(int(exam.get("ai_token_limit", 0)), ai.used_tokens)
        if remaining == 0:
            return Verdict(False, "limit")
        if (
            ai.last_client_id
            and ai.last_client_id != client_id
            and ai.last_used_at is not None
            and now - ai.last_used_at < IN_USE_WINDOW
        ):
            return Verdict(False, "in_use_elsewhere")
        ai.last_client_id = client_id
        ai.last_used_at = now
        ai.save(update_fields=["last_client_id", "last_used_at"])
        return Verdict(True, None, str(exam.get("models", {}).get(tool, "")), remaining)


def record_exchange(
    token: str,
    *,
    tool: str,
    model: str,
    client_id: str,
    input_tokens: int,
    output_tokens: int,
    request: str,
    response: str,
) -> bool:
    """프록시가 넘긴 요청·응답을 적고 사용량을 깎는다. 모르는 토큰이면 False."""

    now = timezone.now()
    with transaction.atomic():
        ai = AIToken.objects.select_for_update().filter(token=token).first()
        if ai is None:
            return False
        AIExchange.objects.create(
            ai_token=ai,
            tool=tool,
            model=model,
            client_id=client_id,
            request=request,
            response=response,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )
        AIToken.objects.filter(pk=ai.pk).update(
            used_tokens=F("used_tokens") + input_tokens + output_tokens,
            last_client_id=client_id,
            last_used_at=now,
        )
    return True
