# syntax=docker/dockerfile:1
# 운영 backend 이미지 — Django + gunicorn. ghcr.io/sandcorporation/infralab-backend:<sha>
# GitHub Actions(image.yml)가 linux/arm64 실행기에서 네이티브로 굽는다. 로컬(amd64)에서도 그대로 빌드된다.
# 개발용은 docker/backend.Dockerfile(runserver, 소스 마운트)이다.

FROM ghcr.io/astral-sh/uv:0.9.30-python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca AS deps
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --locked --no-dev

FROM python:3.15.2-slim-bookworm@sha256:96599df822d0e1c6bb700014a05c7f3c8cabc6e0f7ff3c4f9f69cee033b4b5d9 AS runtime
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
# 배포된 커밋(판). image.yml 이 이미지 태그와 같은 sha 를 넘긴다. 비면 backend 가 dev 로 읽는다.
# 판마다 바뀌므로 캐시가 깨지지 않게 마지막 층 근처에 둔다.
ARG INFRALAB_VERSION=
ENV INFRALAB_VERSION=${INFRALAB_VERSION}
USER app
EXPOSE 8000
CMD ["sh", "-c", "exec gunicorn config.wsgi:application --bind 0.0.0.0:8000 --workers ${GUNICORN_WORKERS:-2} --timeout 30 --access-logfile -"]
