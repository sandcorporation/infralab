#!/usr/bin/env bash
# Runs every factory script test (.github/factory/tests/*.sh) and exits 1 if any fails.
# scripts/ci.sh factory (and so `scripts/ci.sh all`) runs this. The tests put a fake `gh` first on PATH and
# need jq, as the scripts themselves do.
set -u
here=$(cd "$(dirname "$0")" && pwd)

if ! command -v jq >/dev/null 2>&1; then
  echo "공장 스크립트 시험: jq가 없어 건너뜀"
  exit 0
fi

failed=0
for t in "$here"/tests/*.sh; do
  [ -f "$t" ] || continue
  echo "--- $(basename "$t")"
  if ! bash "$t"; then
    echo "FAILED: $(basename "$t")"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "공장 스크립트 시험: 실패"
  exit 1
fi
echo "공장 스크립트 시험: 모두 통과"
