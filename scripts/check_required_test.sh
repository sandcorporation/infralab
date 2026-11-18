#!/usr/bin/env bash
# scripts/check_required.sh 시험(#183): 같으면 0, 잡이 하나 늘거나 빠지면 1.
set -u
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
expect() { # expect <what> <code> <ci.yml>
  bash scripts/check_required.sh "$3" scripts/pr-merge.sh > "$tmp/out" 2>&1
  local got=$?
  if [ "$got" -eq "$2" ]; then echo "  ok   $1"; else echo "  FAIL $1: exit $got, want $2"; cat "$tmp/out"; fails=$((fails + 1)); fi
}
expect "지금 ci.yml" 0 .github/workflows/ci.yml
sed '/^  factory:/,$d' .github/workflows/ci.yml > "$tmp/less.yml"
expect "필수 잡이 빠짐" 1 "$tmp/less.yml"
{ cat .github/workflows/ci.yml; printf '  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'; } > "$tmp/more.yml"
expect "REQUIRED 에 없는 잡" 1 "$tmp/more.yml"
grep -q '빠짐\|ci.yml 에만' "$tmp/out" && echo "  ok   다른 이름을 보여 줌" || { echo "  FAIL 다른 이름이 없음"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] && echo "check_required_test: 통과" || { echo "check_required_test: $fails 실패"; exit 1; }
