"""infralab backend 설정.

값은 전부 환경변수에서 온다 — 개발은 docker/compose.dev.yaml, 운영은 compose.prod.yml(+ 서버의 .env)이
넘긴다. 기본값은 로컬 개발용이다. 운영 환경변수 이름 목록은 docs/ops/deploy.md.
"""

from __future__ import annotations

import os
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
ALLOWED_HOSTS = [h.strip() for h in _env("DJANGO_ALLOWED_HOSTS", "*").split(",") if h.strip()]
# 운영은 web(nginx) 뒤의 리버스 프록시가 TLS 를 끝낸다 — 전체 오리진(https://…)을 콤마로.
CSRF_TRUSTED_ORIGINS = [o.strip() for o in _env("DJANGO_CSRF_TRUSTED_ORIGINS").split(",") if o.strip()]

if not DEBUG:
    from django.core.exceptions import ImproperlyConfigured

    if SECRET_KEY == "dev-only-insecure-key-do-not-use-in-deploy":
        raise ImproperlyConfigured("DJANGO_DEBUG=false 인데 DJANGO_SECRET_KEY 가 개발 기본값이다.")
    # 프록시가 넘기는 X-Forwarded-Proto 를 믿는다(nginx 가 바깥 프록시의 값을 그대로 넘긴다).
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "accounts",
    "orgs",
    "scenarios",
    "cohorts",
    "submissions",
    "exams",
]

# ---------- 학생 compose.yml ----------
# 기본값은 로컬 빌드 이름이다. 운영은 compose.prod.yml 이 Actions 가 게시한 ghcr 주소(배포 sha)를 넘긴다.
AGENT_IMAGE = _env("AGENT_IMAGE", "infralab/agent:dev")
WORKSTATION_IMAGE = _env("WORKSTATION_IMAGE", "infralab/workstation:dev")
FLOCI_IMAGE = _env("FLOCI_IMAGE", "floci/floci:2.3.0")
# 학생 브라우저가 대시보드를 여는 주소(콤마로 여러 개). 에이전트는 이 오리진에서 온 요청만 받는다.
DASHBOARD_ORIGIN = _env("DASHBOARD_ORIGIN", "http://127.0.0.1:53040,http://127.0.0.1:5173")

# 시나리오 YAML 디렉터리. 저장소 레이아웃(backend/ 옆 scenarios/)이 기본, compose 는 /scenarios 로 마운트한다.
SCENARIOS_DIR = _env("SCENARIOS_DIR", str(BASE_DIR.parent / "scenarios"))
# 비공개 문제은행(숨은 검사) 폴더 ← INFRALAB_PROBLEMS_DIR. 비면 숨은 검사를 건너뛴다.
PROBLEMS_DIR = ""  # #69

# ---------- 시험 모드 ----------
# AI 프록시 주소 ← INFRALAB_EXAM_PROXY_URL, 프록시 전용 내부 API 의 공유 비밀 ← INFRALAB_EXAM_PROXY_SECRET.
EXAM_PROXY_URL = ""  # #72
EXAM_PROXY_SECRET = ""  # #72
# 루브릭 채점 키 ← INFRALAB_GRADER_ANTHROPIC_KEY. 비면 가짜 채점기.
GRADER_ANTHROPIC_KEY = ""  # #76

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
]

# 정적 파일: backend 는 /api 만 낸다(django.contrib.staticfiles·admin 없음). 화면의 정적 파일은 web 이미지(nginx)가
# Vite 빌드 산출물을 직접 낸다 — docker/web.Dockerfile.

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
# 로그인은 sandcorp-auth(기밀 클라이언트·PKCE) → Django 세션 쿠키. 규칙은 accounts/sandcorp_auth.py.
# 공개 원점: DASHBOARD_ORIGIN 의 첫 값. redirect_uri 는 {원점}/api/auth/callback, 리소스(aud)는 {원점}/api.
DASHBOARD_ORIGINS = [o.strip().rstrip("/") for o in DASHBOARD_ORIGIN.split(",") if o.strip()]
PUBLIC_ORIGIN = DASHBOARD_ORIGINS[0] if DASHBOARD_ORIGINS else ""
INFRALAB_AUTH_URL = _env("INFRALAB_AUTH_URL", "https://auth.sandcorp.co.kr")
INFRALAB_AUTH_CLIENT_ID = _env("INFRALAB_AUTH_CLIENT_ID")
INFRALAB_AUTH_CLIENT_SECRET = _env("INFRALAB_AUTH_CLIENT_SECRET")
INFRALAB_AUTH_WEBHOOK_SECRET = _env("INFRALAB_AUTH_WEBHOOK_SECRET")
#: 대표 토큰(`acct` 없음)의 `sub`. 다른 sub 의 대표 토큰은 거부한다(A1).
INFRALAB_AUTH_OWNER_SUB = _env("INFRALAB_AUTH_OWNER_SUB", "farrar142")
# openid·profile 이 일반 사용자에게 막힌 클라이언트면 "infralab" 만 줘도 된다 — ID 토큰 없이 sub 로만 로그인한다.
INFRALAB_AUTH_SCOPE = _env("INFRALAB_AUTH_SCOPE", "openid profile infralab")
# 개발용 로그인(POST /api/auth/dev-login) — auth 없이 아무 uid 로나 들어온다. DEBUG 에서만 열린다.
DEV_LOGIN_ENABLED = DEBUG

SESSION_ENGINE = "django.contrib.sessions.backends.db"
SESSION_COOKIE_AGE = 12 * 60 * 60
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SECURE = not DEBUG
