#!/usr/bin/env bash
# scripts/retry.sh 시험(#145) — 가짜 명령으로. 네트워크 없음, 기다림 없음(RETRY_DELAY=0).
#   bash scripts/retry_test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export RETRY_DELAY=0

# 처음 N 번은 not found 로 실패하고 그다음 성공하는 가짜 inspect. 부른 횟수를 $tmp/calls 에 센다.
cat >"$tmp/fake_inspect" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$CALLS"
if [ "$n" -le "$FAIL_TIMES" ]; then echo "ERROR: $1: not found" >&2; exit 1; fi
echo "Name: $1"
FAKE
chmod +x "$tmp/fake_inspect"

pass=0 fail=0
check() {  # 이름, 기대 종료코드, 기대 호출 횟수, 출력에 있어야 할 말, 실패 횟수
  local name="$1" want_rc="$2" want_calls="$3" want_out="$4"; export FAIL_TIMES="$5" CALLS="$tmp/calls.$1"
  local out rc=0
  out="$(bash "$here/retry.sh" "$tmp/fake_inspect" img:sha 2>&1)" || rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$(cat "$CALLS")" = "$want_calls" ] && grep -qF -- "$want_out" <<<"$out"; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name: rc=$rc(want $want_rc) calls=$(cat "$CALLS")(want $want_calls)"; echo "$out" | sed 's/^/     /'
  fi
}

check first-try   0 1 "Name: img:sha" 0
check two-fails   0 3 "Name: img:sha" 2
check always-fail 1 5 "5번 모두 실패" 99

echo "retry_test: $pass 통과, $fail 실패"
[ "$fail" = 0 ]
