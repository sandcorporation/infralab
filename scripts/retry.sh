#!/usr/bin/env bash
# 명령을 성공할 때까지 짧게 다시 돈다(#145). 쓰기 뒤 읽기 지연이 있는 조회(예: GHCR 에 태그를
# push 한 직후 imagetools inspect)를 견디는 데만 쓴다 — 쓰기(create·push) 자체는 감싸지 않는다.
#   scripts/retry.sh <명령> [인자...]
# RETRY_TRIES(기본 5)번 해 보고 사이마다 RETRY_DELAY(기본 2)초부터 두 배씩 기다린다(2·4·8·16).
# 끝내 실패하면 마지막 종료코드로 끝난다.
set -uo pipefail
tries="${RETRY_TRIES:-5}" delay="${RETRY_DELAY:-2}"
[ "$#" -gt 0 ] || { echo "사용법: scripts/retry.sh <명령> [인자...]" >&2; exit 2; }
for ((i = 1; ; i++)); do
  "$@" && exit 0
  rc=$?
  if [ "$i" -ge "$tries" ]; then
    echo "retry.sh: $tries번 모두 실패 (종료코드 $rc): $*" >&2
    exit "$rc"
  fi
  echo "retry.sh: $i/$tries 실패 (종료코드 $rc), ${delay}초 뒤 다시: $*" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
