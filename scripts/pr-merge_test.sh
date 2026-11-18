#!/usr/bin/env bash
# scripts/pr-merge.sh 시험(#164) — 가짜 gh 를 PATH 앞에 둔다. 네트워크 없음, 기다림 없음(PR_MERGE_POLL=0).
#   bash scripts/pr-merge_test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PR_MERGE_POLL=0

# 가짜 gh: `pr view` 는 $SCEN/<n>.json 을 차례로(마지막 것은 되풀이) 돌려주고, `pr merge` 는 인자를 $SCEN/merged 에 적는다.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    if [ -f "$SCEN/merged" ]; then echo '{"state":"MERGED"}'; exit 0; fi
    n=$(( $(cat "$SCEN/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$SCEN/calls"
    f="$SCEN/$n.json"; [ -f "$f" ] || f="$(ls "$SCEN"/*.json | sort -V | tail -n 1)"
    cat "$f" ;;
  "pr merge") shift 2; echo "$*" >"$SCEN/merged" ;;
  *) echo "fake gh: 모르는 명령 $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# run(이름, 단계 순서대로 rollup JSON 들…) → $tmp/<이름> 시나리오. rollup 하나는 [{…},…] 배열.
run() {
  local name="$1"; shift; export SCEN="$tmp/$name"; mkdir -p "$SCEN"; local i=0
  for r in "$@"; do i=$((i + 1)); printf '{"state":"OPEN","headRefOid":"abc123","statusCheckRollup":%s}\n' "$r" >"$SCEN/$i.json"; done
}
cr() {  # 이름 status conclusion → CheckRun 하나(workflow ci)
  printf '{"__typename":"CheckRun","name":"%s","workflowName":"ci","status":"%s","conclusion":"%s","detailsUrl":"https://example.test/%s"}' "$1" "$2" "$3" "$1"
}
all() {  # status conclusion [바꿀 잡 status conclusion] → 필수 다섯 잡
  local out="" j
  for j in backend web agent exam-proxy-route e2e factory; do
    if [ "${3:-}" = "$j" ]; then out+="$(cr "$j" "$4" "$5"),"; else out+="$(cr "$j" "$1" "$2"),"; fi
  done
  echo "[${out%,}]"
}

pass=0 fail=0
check() {  # 이름 기대코드 병합했나(yes/no) 출력에-있어야-할-말 [환경…]
  local name="$1" want_rc="$2" want_merged="$3" want_out="$4"; shift 4
  export SCEN="$tmp/$name"
  local out rc=0 merged=no
  out="$(env "$@" bash "$here/pr-merge.sh" 7 2>&1)" || rc=$?
  [ -f "$SCEN/merged" ] && merged=yes
  if [ "$rc" = "$want_rc" ] && [ "$merged" = "$want_merged" ] && grep -qF -- "$want_out" <<<"$out"; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name: rc=$rc(want $want_rc) merged=$merged(want $want_merged)"; echo "$out" | sed 's/^/     /'
  fi
}

# 미등록 → 기다림 → 진행 중 → 모두 SUCCESS → 병합(검사를 읽은 head 로).
run unregistered-then-green '[]' '[]' "$(all IN_PROGRESS '')" "$(all COMPLETED SUCCESS)"
check unregistered-then-green 0 yes "검사 모두 초록"
grep -qF -- "--squash --delete-branch --match-head-commit abc123" "$tmp/unregistered-then-green/merged" \
  && { pass=$((pass + 1)); echo "ok   merge-args"; } || { fail=$((fail + 1)); echo "FAIL merge-args: $(cat "$tmp/unregistered-then-green/merged")"; }
[ "$(cat "$tmp/unregistered-then-green/calls")" = 4 ] \
  && { pass=$((pass + 1)); echo "ok   waited-4-polls"; } || { fail=$((fail + 1)); echo "FAIL waited-4-polls: $(cat "$tmp/unregistered-then-green/calls")"; }

# 끝까지 등록되지 않음 → 병합 안 함(#118: 검사 없음을 통과로 읽지 않는다).
run never-registered '[]'
check never-registered 3 no "등록되지 않았다" PR_MERGE_REGISTER_WAIT=0

# 하나 FAILURE(나머지는 진행 중이어도) → 곧바로 멈추고 이름·링크를 찍는다(#159).
run one-failure "$(all IN_PROGRESS '' backend COMPLETED FAILURE)"
check one-failure 1 no "backend  FAILURE  https://example.test/backend"

# 필수 잡이 SKIPPED → 병합 안 함.
run required-skipped "$(all COMPLETED SUCCESS web COMPLETED SKIPPED)"
check required-skipped 1 no "web  SKIPPED"

# 필수 아닌 검사의 실패도 막는다. SKIPPED 인 필수 아닌 검사는 괜찮다.
run other-failure "[$(cr backend COMPLETED SUCCESS),$(cr web COMPLETED SUCCESS),$(cr agent COMPLETED SUCCESS),$(cr exam-proxy-route COMPLETED SUCCESS),$(cr e2e COMPLETED SUCCESS),$(cr factory COMPLETED SUCCESS),{\"__typename\":\"StatusContext\",\"context\":\"jenkins\",\"state\":\"ERROR\",\"targetUrl\":\"https://example.test/j\"}]"
check other-failure 1 no "jenkins  ERROR"
run other-skipped "[$(cr backend COMPLETED SUCCESS),$(cr web COMPLETED SUCCESS),$(cr agent COMPLETED SUCCESS),$(cr exam-proxy-route COMPLETED SUCCESS),$(cr e2e COMPLETED SUCCESS),$(cr factory COMPLETED SUCCESS),{\"__typename\":\"CheckRun\",\"name\":\"label\",\"workflowName\":\"other\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\"}]"
check other-skipped 0 yes "검사 모두 초록"

# 같은 이름이라도 다른 workflow 의 잡은 필수 잡으로 치지 않는다 → 끝내 미등록.
run wrong-workflow "[{\"__typename\":\"CheckRun\",\"name\":\"backend\",\"workflowName\":\"factory-verify\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]"
check wrong-workflow 3 no "등록되지 않았다" PR_MERGE_REGISTER_WAIT=0

# 끝나지 않음 → 시간 초과.
run never-finishes "$(all IN_PROGRESS '')"
check never-finishes 3 no "끝나지 않았다" PR_MERGE_TOTAL_WAIT=0

# 사용법.
rc=0; bash "$here/pr-merge.sh" abc >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && { pass=$((pass + 1)); echo "ok   bad-arg"; } || { fail=$((fail + 1)); echo "FAIL bad-arg: rc=$rc"; }

echo "pr-merge_test: $pass 통과, $fail 실패"
[ "$fail" = 0 ]
