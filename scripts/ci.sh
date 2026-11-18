#!/usr/bin/env bash
# PR 검사와 같은 검사를 저장소 루트에서 한 명령으로 돈다.
#   scripts/ci.sh <backend|web|agent|factory|release|all>
# 필요: backend=uv + 접근 가능한 Postgres(POSTGRES_HOST·PORT 등, 기본 127.0.0.1:55440),
#       web=node+npm, agent=go(agent/·proxy/), factory=bash·jq·git (가짜 gh 로 공장 스크립트 시험),
#       release=bash·git (production 승격 스크립트 시험, 로컬 bare 저장소).
set -euo pipefail
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "ci.sh: '$1' 가 필요합니다 ($2)" >&2; exit 127; }; }

backend() {
  need uv "backend 시험"
  (cd backend && uv sync --locked && uv run pytest)
}

web() {
  need npm "web 검사 (node 필요)"
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
}

case "${1:-}" in
  backend) backend ;;
  web) web ;;
  agent) agent ;;
  factory) factory ;;
  release) release ;;
  all) backend; web; agent; factory; release ;;
  *) echo "사용법: scripts/ci.sh <backend|web|agent|factory|release|all>" >&2; exit 2 ;;
esac
