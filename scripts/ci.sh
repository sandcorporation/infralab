#!/usr/bin/env bash
# PR 검사와 같은 검사를 저장소 루트에서 한 명령으로 돈다.
#   scripts/ci.sh <backend|web|agent|factory|release|all>
# 필요: backend=uv + 접근 가능한 Postgres(POSTGRES_HOST·PORT 등, 기본 127.0.0.1:55440),
#       web=node+npm, agent=go(agent/·proxy/), factory=bash·jq·git (가짜 gh 로 공장 스크립트 시험),
#       release=bash·git·jq·python3 (production 승격 스크립트 시험, 로컬 bare 저장소, 병합 장치 시험).
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
  # 병합 장치(#164): CI 초록일 때만 병합하는 스크립트(로컬 작업자·공장 공용, #172).
  bash scripts/pr-merge_test.sh
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
