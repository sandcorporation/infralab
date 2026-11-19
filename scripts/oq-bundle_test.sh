#!/usr/bin/env bash
# scripts/oq-bundle.sh 시험(#248) — 가짜 gh 를 PATH 앞에 둔다. 네트워크 없음.
#   bash scripts/oq-bundle_test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 가짜 gh: `issue view` 는 $SCEN/issue.json 을 돌려주고 받은 인자를 $SCEN/args 에 적는다. issue.json 이 없으면 실패.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view")
    shift 2; echo "$*" >"$SCEN/args"
    [ -f "$SCEN/issue.json" ] || { echo "GraphQL: Could not resolve to an issue" >&2; exit 1; }
    cat "$SCEN/issue.json" ;;
  *) echo "fake gh: 모르는 명령 $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# scen(이름, 라벨 JSON 배열, 본문) → $tmp/<이름>/issue.json
scen() {
  mkdir -p "$tmp/$1"
  jq -n --argjson labels "$2" --arg body "$3" '{labels: $labels, body: $body}' >"$tmp/$1/issue.json"
}

body_with_oq='# 웹캠 spec

## 무엇
본문.

## Open Questions
1. 해상도는?
### 세부
- 프레임 수는?
```sh
# 코드 안 주석은 제목이 아니다
```
2. 저장은?

## 인수 조건
- [ ] 무엇'

pass=0 fail=0
# check(이름, 기대코드, 기대 stdout(정확히), stderr 에 있어야 할 말(빈 문자열이면 stderr 도 비어야) [환경…])
check() {
  local name="$1" want_rc="$2" want_out="$3" want_err="$4"; shift 4
  export SCEN="$tmp/$name"; mkdir -p "$SCEN"
  local rc=0
  env "$@" bash "$here/oq-bundle.sh" 236 >"$SCEN/out" 2>"$SCEN/err" || rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$(cat "$SCEN/out")" = "$want_out" ] && { if [ -z "$want_err" ]; then [ ! -s "$SCEN/err" ]; else grep -qF -- "$want_err" "$SCEN/err"; fi; }; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name: rc=$rc(want $want_rc)"
    sed 's/^/     out: /' "$SCEN/out"; sed 's/^/     err: /' "$SCEN/err"
  fi
}

# deferred → 거절, stdout 비움(절이 있어도).
scen deferred '[{"name":"spec"},{"name":"deferred"}]' "$body_with_oq"
check deferred 1 "" "deferred"

# 라벨 이름을 FACTORY_LABEL_DEFERRED 로 바꾸면 그 라벨에서 거절하고, 옛 이름은 더 이상 거절하지 않는다.
scen custom-label '[{"name":"human:deferred"}]' "$body_with_oq"
check custom-label 1 "" "human:deferred" FACTORY_LABEL_DEFERRED=human:deferred
scen custom-label-old '[{"name":"deferred"}]' '## Open Questions
- ?'
check custom-label-old 0 '## Open Questions
- ?' "" FACTORY_LABEL_DEFERRED=human:deferred

# deferred 없음 + 절 있음 → 그 절만(하위 제목·코드 울타리 포함, 다음 ## 앞까지).
scen with-oq '[{"name":"spec"}]' "$body_with_oq"
check with-oq 0 '## Open Questions
1. 해상도는?
### 세부
- 프레임 수는?
```sh
# 코드 안 주석은 제목이 아니다
```
2. 저장은?' ""

# 절이 끝까지 가고 CRLF 본문·단수 제목·제목 단계가 달라도 된다.
scen last-section '[]' $'## 무엇\r\n본문\r\n### Open Question\r\n- 하나?\r\n'
check last-section 0 '### Open Question
- 하나?' ""

# 절 없음 → 거절.
scen no-oq '[{"name":"spec"}]' '## 무엇
Open Questions 라는 말은 있지만 제목은 아니다.'
check no-oq 3 "" "Open Questions 절이 없습니다"

# 조회 실패(이슈 없음) → 4.
check gone 4 "" "읽지 못했습니다"

# 사용법.
rc=0; bash "$here/oq-bundle.sh" abc >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); echo "ok   usage"; else fail=$((fail + 1)); echo "FAIL usage: rc=$rc(want 2)"; fi

# FACTORY_REPO 가 있으면 --repo 로 넘기고, 없으면 넘기지 않는다.
scen repo '[]' '## Open Questions
- ?'
check repo 0 '## Open Questions
- ?' "" FACTORY_REPO=example/repo
if grep -qF -- "--repo example/repo" "$tmp/repo/args" && ! grep -qF -- "--repo" "$tmp/with-oq/args"; then
  pass=$((pass + 1)); echo "ok   repo-args"
else
  fail=$((fail + 1)); echo "FAIL repo-args: $(cat "$tmp/repo/args") / $(cat "$tmp/with-oq/args")"
fi

echo "oq-bundle_test: $pass 통과, $fail 실패"
[ "$fail" = 0 ]
