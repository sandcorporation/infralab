#!/usr/bin/env bash
# workstation 이미지 환경 시험(#125). workstation 은 root 로 돈다 — Claude Code 는 root 에서
# `--dangerously-skip-permissions` 를 IS_SANDBOX=1 이 없으면 거부한다. 응시자 전용 격리 컨테이너라 이미지에 둔다.
# 이미지 빌드 검증 줄(Dockerfile 끝 RUN)도 같은 것을 실제 claude 로 본다 — 여기는 PR 에서 도는 정적 확인.
set -euo pipefail
cd "$(dirname "$0")/.."
f=docker/workstation/Dockerfile
if grep -Eq '^ENV[[:space:]]+IS_SANDBOX=1([[:space:]]|$)' "$f"; then
  echo "ok   $f: ENV IS_SANDBOX=1"
else
  echo "FAIL $f: ENV IS_SANDBOX=1 이 없다 — root 에서 claude --dangerously-skip-permissions 가 거부된다" >&2
  exit 1
fi
