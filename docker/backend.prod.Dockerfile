# syntax=docker/dockerfile:1
# 운영 backend 이미지 — Django + gunicorn. ghcr.io/sandcorporation/infralab-backend:<sha>
# GitHub Actions(image.yml)가 linux/arm64 실행기에서 네이티브로 굽는다. 로컬(amd64)에서도 그대로 빌드된다.
# 개발용은 docker/backend.Dockerfile(runserver, 소스 마운트)이다.

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS deps
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --locked --no-dev

FROM python:3.13-slim-bookworm AS runtime
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DJANGO_DEBUG=false \
    SCENARIOS_DIR=/scenarios
WORKDIR /app
COPY --from=deps /opt/venv /opt/venv
COPY backend/ ./
# 시나리오 YAML 은 서버가 시작 때 읽는다.
COPY scenarios/ /scenarios/
RUN useradd --uid 1000 --no-create-home app
USER app
EXPOSE 8000
CMD ["sh", "-c", "exec gunicorn config.wsgi:application --bind 0.0.0.0:8000 --workers ${GUNICORN_WORKERS:-2} --timeout 30 --access-logfile -"]
