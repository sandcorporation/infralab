#!/usr/bin/env bash
# PR 검사와 같은 검사를 저장소 루트에서 한 명령으로 돈다.
#   scripts/ci.sh <backend|web|agent|factory|release|e2e|all>
# 필요: backend=uv + 접근 가능한 Postgres(POSTGRES_HOST·PORT 등, 기본 127.0.0.1:55440),
#       web=node+npm, agent=go(agent/·proxy/), factory=bash·jq·git (가짜 gh 로 공장 스크립트 시험),
#       release=bash·git·jq·python3 (production 승격 스크립트 시험, 로컬 bare 저장소, 병합 장치 시험),
#       e2e=docker(compose)·node+npm·curl (개발 스택을 띄워 Playwright 로 브라우저 시험, 127.0.0.1:7777 이 비어 있어야 한다).
set -euo pipefail
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "ci.sh: '$1' 가 필요합니다 ($2)" >&2; exit 127; }; }

backend() {
  need uv "backend 시험"
  (cd backend && uv sync --locked && uv run pytest)
}

web() {
  need npm "web 검사 (node 필요)"
  # 디자인시스템(sandcorp-design) 의존성·색 리터럴 검사(#135)와 그 시험.
  node scripts/check_design.mjs
  bash scripts/check_design_test.sh
  (cd web && npm ci && npm run typecheck && npm run test --if-present && npm run build)
}

# Go 모듈 검사: gofmt·vet·test. agent 와 AI 프록시(proxy/)가 같은 Go 판(agent/go.mod)을 쓴다.
gomod() {
  (
    cd "$1"
    out="$(gofmt -l .)"
    if [ -n "$out" ]; then echo "$1: gofmt 가 필요한 파일:" >&2; echo "$out" >&2; exit 1; fi
    go vet ./...
    go test ./...
  )
}

agent() {
  need go "agent·proxy 검사"
  gomod agent
  gomod proxy
}

factory() {
  need jq "공장 스크립트 시험"
  bash .github/factory/test.sh
}

release() {
  bash scripts/promote_test.sh
  bash scripts/check_image_pins_test.sh
  bash scripts/check_workstation_env_test.sh
  bash scripts/retry_test.sh
  # 병합 장치(#164): CI 초록일 때만 병합하는 스크립트와 직접 병합을 막는 Claude Code 훅.
  bash scripts/pr-merge_test.sh
  bash .claude/hooks/block-direct-merge_test.sh
}

# 브라우저 e2e(#168): 개발 스택(compose.dev.yaml + compose.e2e.yaml)을 따로 프로젝트 이름으로 올리고
# web/e2e/*.spec.ts 를 돈 뒤, 성공·실패와 상관없이 컨테이너·볼륨을 지운다. 「사람 확인」을 대신하는 시험이다.
# all 에는 넣지 않는다 — PR 검사의 e2e 잡(ci.yml)이 따로 돈다. 뒤 인자는 playwright test 로 간다(예: e2e -g 붙여넣기).
E2E_PROJECT=infralab-e2e
e2e_compose() {
  docker compose -p "$E2E_PROJECT" -f docker/compose.dev.yaml -f docker/compose.e2e.yaml --profile agent "$@"
}
e2e_down() {
  e2e_compose down -v --remove-orphans >/dev/null 2>&1 || true
}
e2e() {
  need docker "e2e 스택"
  need npm "e2e (node 필요)"
  need curl "e2e 스택 대기"
  export INFRALAB_DB_PORT="${INFRALAB_DB_PORT:-55450}" INFRALAB_API_PORT="${INFRALAB_API_PORT:-58050}" \
    INFRALAB_WEB_PORT="${INFRALAB_WEB_PORT:-53050}"
  if (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null; then
    echo "ci.sh e2e: 127.0.0.1:7777 을 다른 프로세스(학생 에이전트?)가 쓴다 — 내리고 다시 돌린다" >&2
    exit 1
  fi
  e2e_down
  trap e2e_down EXIT
  local started=$SECONDS
  e2e_compose build agent
  e2e_compose up -d db backend web workstation
  (cd web && npm ci --no-audit --no-fund && npx playwright install ${CI:+--with-deps} chromium)
  local base="http://127.0.0.1:$INFRALAB_WEB_PORT"
  # web 컨테이너는 npm install 뒤 Vite 를 띄운다 — /api 까지 닿아야(로그인 전 401) 준비된 것이다.
  local code="" i
  for i in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$base/api/accounts/me" || true)"
    [ "$code" = 401 ] && break
    sleep 2
  done
  if [ "$code" != 401 ]; then
    echo "ci.sh e2e: 스택이 4분 안에 뜨지 않았다(/api/accounts/me → $code)" >&2
    e2e_compose logs --tail 40 backend web >&2 || true
    exit 1
  fi
  echo "ci.sh e2e: 스택 준비 $((SECONDS - started))초"
  (cd web && E2E_BASE_URL="$base" E2E_PROJECT="$E2E_PROJECT" npx playwright test "${@:2}")
}

case "${1:-}" in
  backend) backend ;;
  web) web ;;
  agent) agent ;;
  factory) factory ;;
  release) release ;;
  e2e) e2e "$@" ;;
  all) backend; web; agent; factory; release ;;
  *) echo "사용법: scripts/ci.sh <backend|web|agent|factory|release|e2e|all>" >&2; exit 2 ;;
esac
