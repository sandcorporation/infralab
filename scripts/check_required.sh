#!/usr/bin/env bash
# 필수 검사 목록 드리프트(#183): ci.yml 의 잡 이름 == scripts/pr-merge.sh 의 REQUIRED 인지 본다.
# 세 번째 자리(main ruleset 27560028)는 네트워크가 필요해 scripts/check_ruleset.sh 가 본다.
#   scripts/check_required.sh [ci.yml] [pr-merge.sh]      scripts/ci.sh release 가 돈다.
set -euo pipefail
cd "$(dirname "$0")/.."
ci=${1:-.github/workflows/ci.yml}
merge=${2:-scripts/pr-merge.sh}

jobs=$(awk '/^jobs:/ { j = 1; next } j && /^[^[:space:]#]/ { j = 0 }
  j && /^  [A-Za-z0-9_-]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }' "$ci" | sort)
required=$(sed -n 's/^REQUIRED=(\(.*\))[[:space:]]*$/\1/p' "$merge" | tr ' ' '\n' | sed '/^$/d' | sort)
[ -n "$required" ] || { echo "check_required: $merge 에서 REQUIRED=(…) 를 찾지 못함" >&2; exit 1; }
if [ "$jobs" != "$required" ]; then
  echo "check_required: $ci 잡과 $merge REQUIRED 가 다르다" >&2
  diff <(printf '%s\n' "$jobs") <(printf '%s\n' "$required") | sed 's/^</  ci.yml 에만:/; s/^>/  REQUIRED 에만:/' | grep '에만' >&2
  exit 1
fi
echo "check_required: ci.yml 잡 == pr-merge.sh REQUIRED ($(printf '%s' "$required" | tr '\n' ' '))"
