# syntax=docker/dockerfile:1
FROM ghcr.io/astral-sh/uv:0.9.30-python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca

# 가상환경을 /app 밖에 둔다 — dev compose 가 소스를 /app 에 바인드 마운트하므로 안에 두면 가려진다.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# 락파일만 먼저 복사해 의존성 레이어를 캐시한다.
COPY backend/pyproject.toml backend/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

COPY backend/ ./
# 시나리오 YAML 은 서버가 시작 때 읽는다 — 이미지 혼자서도 뜨게 함께 넣는다. dev compose 는 같은
# 자리에 저장소의 scenarios/ 를 마운트해 덮는다.
COPY scenarios/ /scenarios/
ENV SCENARIOS_DIR=/scenarios

EXPOSE 8000
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
