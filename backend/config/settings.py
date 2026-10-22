"""infralab backend 설정.

값은 전부 환경변수에서 온다 — 개발 compose(docker/compose.dev.yaml)가 넘긴다. 기본값은
로컬 프로토타입용이고, 배포는 이번 범위가 아니다(스펙 Out of Scope).
"""

from __future__ import annotations

import os
from datetime import timedelta
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _env(name: str, default: str = "") -> str:
    # 빈 값은 「안 줌」으로 본다 — compose 의 `${X:-}` 치환이 빈 문자열을 넘기기 때문이다.
    return os.environ.get(name) or default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


DEBUG = _env_bool("DJANGO_DEBUG", True)
SECRET_KEY = _env("DJANGO_SECRET_KEY", "dev-only-insecure-key-do-not-use-in-deploy")
ALLOWED_HOSTS = [h for h in _env("DJANGO_ALLOWED_HOSTS", "*").split(",") if h]

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "accounts",
    "scenarios",
    "cohorts",
]

# 시나리오 YAML 디렉터리. 저장소 레이아웃(backend/ 옆 scenarios/)이 기본, compose 는 /scenarios 로 마운트한다.
SCENARIOS_DIR = _env("SCENARIOS_DIR", str(BASE_DIR.parent / "scenarios"))

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": _env("POSTGRES_DB", "infralab"),
        "USER": _env("POSTGRES_USER", "infralab"),
        "PASSWORD": _env("POSTGRES_PASSWORD", "infralab"),
        "HOST": _env("POSTGRES_HOST", "127.0.0.1"),
        "PORT": _env("POSTGRES_PORT", "55440"),
    }
}

AUTH_USER_MODEL = "accounts.User"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LANGUAGE_CODE = "ko-kr"
TIME_ZONE = "Asia/Seoul"
USE_I18N = True
USE_TZ = True

# ---------- 인증 ----------
# 액세스 토큰은 짧게, 리프레시 토큰은 회전시킨다. 서명 키는 SECRET_KEY 와 분리해 둘 수 있다.
JWT_SIGNING_KEY = _env("JWT_SIGNING_KEY") or SECRET_KEY
ACCESS_TOKEN_TTL = timedelta(minutes=int(_env("ACCESS_TOKEN_TTL_MINUTES", "30")))
REFRESH_TOKEN_TTL = timedelta(days=int(_env("REFRESH_TOKEN_TTL_DAYS", "14")))

# 소셜 어댑터 바인딩. DEBUG 에서는 fake 가 기본 — 카카오 키 없이 로컬·시험이 돈다. DEBUG 가
# 꺼진 곳에서 fake 는 누구나 임의 uid 로(강사 포함) 로그인하는 구멍이라 기본도 real 이고 fake 를
# 명시해도 부팅을 막는다.
SOCIAL_AUTH_MODE = _env("SOCIAL_AUTH_MODE", "fake" if DEBUG else "real")
if not DEBUG and SOCIAL_AUTH_MODE == "fake":
    from django.core.exceptions import ImproperlyConfigured

    raise ImproperlyConfigured("DJANGO_DEBUG=false 인데 SOCIAL_AUTH_MODE 가 fake 다 — 인증 우회가 된다.")
