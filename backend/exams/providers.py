"""시험 공급사 설정 여부 — 어떤 공급사 키가 AI 프록시에 들어 있는지(키 값이 아니라 있다·없다만).

공급사 키는 프록시만 갖는다. backend 는 프록시 내부 `GET /providers` 를 공유 비밀로 짧게 묻고 잠깐 기억한다.
프록시를 못 부르면(비밀이 없는 개발·시험 환경, 프록시가 죽음) 「모름」이고, 모르면 아무 도구도 막지 않는다.
"""

from __future__ import annotations

import json
import threading
import time
import urllib.request
from typing import Literal, TypedDict

from django.conf import settings

Provider = Literal["anthropic", "openai"]
#: 도구 → 그 도구가 쓰는 공급사. 로컬 LLM 은 공급사 키가 필요 없다.
TOOL_PROVIDER: dict[str, Provider] = {"claude_code": "anthropic", "codex": "openai"}
#: 프록시 응답을 기억하는 시간(초)과 묻는 제한 시간(초).
CACHE_SECONDS = 30.0
TIMEOUT_SECONDS = 1.0


class Providers(TypedDict):
    anthropic: bool
    openai: bool


_lock = threading.Lock()
_cached: tuple[float, Providers | None] | None = None


def _fetch() -> Providers | None:
    """프록시에 묻는다. 비밀이 없거나 어떤 식으로든 실패하면 None(모름)."""

    if not settings.EXAM_PROXY_SECRET:
        return None
    req = urllib.request.Request(
        f"{settings.EXAM_PROXY_URL.rstrip('/')}/providers",
        headers={"Authorization": f"Bearer {settings.EXAM_PROXY_SECRET}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as res:
            data = json.loads(res.read())
    except Exception:  # noqa: BLE001 — 어떤 실패든 「모름」 하나로 본다
        return None
    if not isinstance(data, dict):
        return None
    a, o = data.get("anthropic"), data.get("openai")
    if not isinstance(a, bool) or not isinstance(o, bool):
        return None
    return {"anthropic": a, "openai": o}


def configured() -> Providers | None:
    """공급사마다 키가 설정됐는지. 모르면 None. CACHE_SECONDS 동안 기억한다."""

    global _cached
    now = time.monotonic()
    with _lock:
        if _cached is not None and now - _cached[0] < CACHE_SECONDS:
            return _cached[1]
    value = _fetch()
    with _lock:
        _cached = (time.monotonic(), value)
    return value


def clear_cache() -> None:
    global _cached
    with _lock:
        _cached = None


def unavailable_tools() -> list[str]:
    """공급사 키가 설정되지 않은 것이 확실한 도구. 모르면 빈 목록."""

    known = configured()
    if known is None:
        return []
    return [tool for tool, provider in TOOL_PROVIDER.items() if not known[provider]]


def missing_message(tool: str) -> str:
    return f"{tool} 의 공급사({TOOL_PROVIDER[tool]}) 키가 AI 프록시에 설정되지 않아 고를 수 없습니다."
