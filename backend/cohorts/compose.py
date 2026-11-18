"""학생 PC 에 내려 주는 compose.yml.

`docker compose up -d` 하나로 에이전트·workstation·Floci·네트워크가 올라온다. 컨테이너 이름은 고정이다
— 에이전트가 그 이름으로 workstation·Floci 를 찾는다. 토큰은 학생(참여)마다 다르고, 이미지 태그와
대시보드 오리진은 서버 설정값이다(운영은 배포 sha 의 ghcr 주소 — docs/ops/deploy.md).
"""

from __future__ import annotations

from urllib.parse import urlsplit

from django.conf import settings

AGENT_CONTAINER = "infralab-agent"
WORKSTATION_CONTAINER = "infralab-workstation"
FLOCI_CONTAINER = "infralab-floci"
AGENT_PORT = 7777


def allowed_origins(dashboard_origins: str) -> list[str]:
    """콤마로 구분한 대시보드 오리진을 scheme://host[:port] 로 정규화한다(뒤 슬래시·경로는 버린다 — 브라우저의
    Origin 헤더와 글자 그대로 비교되기 때문). 호스트가 127.0.0.1/localhost 면 둘 다 넣는다."""

    out: list[str] = []
    for raw in dashboard_origins.split(","):
        raw = raw.strip()
        if not raw:
            continue
        parts = urlsplit(raw)
        if not parts.scheme or not parts.hostname:
            continue
        port = f":{parts.port}" if parts.port else ""
        hosts = [parts.hostname]
        if parts.hostname in ("127.0.0.1", "localhost"):
            hosts.append("localhost" if parts.hostname == "127.0.0.1" else "127.0.0.1")
        for host in hosts:
            origin = f"{parts.scheme}://{host}{port}"
            if origin not in out:
                out.append(origin)
    return out


def render_compose(*, agent_token: str, cohort_name: str) -> str:
    origins = ",".join(allowed_origins(settings.DASHBOARD_ORIGIN))
    # 주석 한 줄에 들어간다 — 줄바꿈이 있으면 주석을 벗어나 YAML 을 깨뜨린다.
    safe_name = " ".join(cohort_name.split())
    return f"""# infralab — {safe_name}
# 이 폴더에서: docker compose up -d
# ./work 가 workstation 의 /work, 볼륨 home 이 /root 다. 에이전트 토큰이 들어 있으니 공유하지 않는다.

name: infralab

services:
  agent:
    image: {settings.AGENT_IMAGE}
    container_name: {AGENT_CONTAINER}
    restart: unless-stopped
    ports:
      # 127.0.0.1 에만 듣는다 — 같은 와이파이의 다른 사람은 닿지 못한다.
      - "127.0.0.1:{AGENT_PORT}:{AGENT_PORT}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      AGENT_TOKEN: "{agent_token}"
      AGENT_ALLOWED_ORIGINS: "{origins}"
      WORKSTATION_CONTAINER: {WORKSTATION_CONTAINER}
      FLOCI_CONTAINER: {FLOCI_CONTAINER}
    networks: [lab]

  workstation:
    image: {settings.WORKSTATION_IMAGE}
    container_name: {WORKSTATION_CONTAINER}
    restart: unless-stopped
    command: ["sleep", "infinity"]
    working_dir: /work
    volumes:
      - ./work:/work
      # 홈(/root) — claude·codex 로그인 토큰과 세션 파일이 여기 남는다.
      - home:/root
    environment:
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_DEFAULT_REGION: ap-northeast-2
      AWS_ENDPOINT_URL: http://{FLOCI_CONTAINER}:4566
      TERM: xterm-256color
    networks: [lab]

  floci:
    image: {settings.FLOCI_IMAGE}
    container_name: {FLOCI_CONTAINER}
    restart: unless-stopped
    volumes:
      # EC2·RDS 를 실제 컨테이너로 띄우기 위해 필요하다.
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [lab]

volumes:
  home:

networks:
  lab:
    name: infralab
"""
