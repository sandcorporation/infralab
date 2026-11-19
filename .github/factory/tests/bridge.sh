#!/usr/bin/env bash
# Tests of .github/factory/bridge.sh (labels and marker comments → switchboard mailbox, #410) against the
# fake gh and switchboard. Recipients are made-up names (test/…).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../bridge.sh"
export PATH="$here/fake:$PATH"

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FAKE_MAIL="$tmp/mail" XDG_STATE_HOME="$tmp/state"
  export BRIDGE_SINCE=2026-11-01T00:00:00Z
  unset BRIDGE_STATE_DIR BRIDGE_TO BRIDGE_CC SWITCHBOARD_PROFILE FACTORY_SPEC_QUEUE BRIDGE_TRUSTED_BOTS BRIDGE_HUMAN_CHECK_TO
  export FACTORY_REPO=owner/facet # the copy of this kit in any repository passes these tests as is (#437)
  export BRIDGE_TO_BOSS=test/boss BRIDGE_TO_COORD=test/coord
  mkdir -p "$FAKE_GH" "$FAKE_MAIL"
  echo '[]' > "$FAKE_GH/repo-comments.json"
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}

# issue <n> <state> <labels comma-separated> <title> [body]
issue() {
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg t "$4" --arg b "${5:-}" \
    '{number: $n, state: $s, title: $t, body: $b, html_url: "https://github.com/owner/repo/issues/\($n)",
      labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# labeled <n> <label> <time>: a `labeled` event in the issue's timeline
labeled() {
  local f="$FAKE_GH/timeline-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg l "$2" --arg t "$3" '. + [{event: "labeled", created_at: $t, label: {name: $l}}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

# unlabel <n> <label>: takes the label off the issue
unlabel() {
  jq --arg l "$2" '.labels |= map(select(.name != $l))' "$FAKE_GH/issue-$1.json" | tr -d '\r' \
    > "$FAKE_GH/issue-$1.json.new" && mv "$FAKE_GH/issue-$1.json.new" "$FAKE_GH/issue-$1.json"
}

# relabel <n> <label>: puts the label on (again)
relabel() {
  jq --arg l "$2" '.labels += [{name: $l}]' "$FAKE_GH/issue-$1.json" | tr -d '\r' \
    > "$FAKE_GH/issue-$1.json.new" && mv "$FAKE_GH/issue-$1.json.new" "$FAKE_GH/issue-$1.json"
}

# icomment <issue> <id> <body> [author] [created_at]: a comment on that issue (read for the reason)
icomment() {
  local f="$FAKE_GH/comments-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson id "$2" --arg b "$3" --arg u "${4:-github-actions[bot]}" --arg t "${5:-2026-11-17T03:00:00Z}" \
    '. + [{id: $id, body: $b, user: {login: $u}, created_at: $t}]' "$f" | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

# comment <id> <issue> <body> [author login, default github-actions[bot]]: a repository comment (markers)
comment() {
  local f="$FAKE_GH/repo-comments.json"
  jq --argjson id "$1" --arg n "$2" --arg b "$3" --arg u "${4:-github-actions[bot]}" \
    '. + [{id: $id, body: $b, user: {login: $u}, created_at: "2026-11-17T03:00:00Z",
           issue_url: "https://api.github.com/repos/owner/repo/issues/\($n)",
           html_url: "https://github.com/owner/repo/issues/\($n)#issuecomment-\($id)"}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

run() { bash "$script" "$@" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }
code() { cat "$tmp/code"; }
sent_count() { [ -f "$FAKE_MAIL/sent.jsonl" ] && wc -l < "$FAKE_MAIL/sent.jsonl" | tr -d ' ' || echo 0; }
# arg <send index from 0> <option>: the value after the option in that send
arg() {
  jq -s -r --argjson i "$1" --arg o "$2" '.[$i].args as $a | ($a | index($o)) as $k | $a[$k + 1]' \
    "$FAKE_MAIL/sent.jsonl" | tr -d '\r'
}
# tos: every send's recipient, space-separated
tos() { jq -s -r '[.[].args as $a | $a[($a | index("--to")) + 1]] | join(" ")' "$FAKE_MAIL/sent.jsonl" 2> /dev/null | tr -d '\r'; }
state() { tr -d '\r' < "$XDG_STATE_HOME/facet-factory-bridge/sent"; }

# --- labels (#410 더함 2, 14번) ----------------------------------------------------------------------

setup "ready-for-human without any marker comment is sent once, saying there is no reason comment"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq to test/coord "$(arg 0 --to)"
eq task facet-factory "$(arg 0 --task)"
eq key "facet-factory-label-301-ready-for-human-2026-11-18T01-00-00Z-test-coord" "$(arg 0 --idempotency-key)"
eq subject "[facet 공장] 사람 넘김(other): #301 티켓 하나" "$(arg 0 --subject)"
has body "까닭 댓글 없음" "$(arg 0 --body)"
has "body link" "https://github.com/owner/repo/issues/301" "$(arg 0 --body)"
eq "first line names the code (#437)" "종류: 사람 넘김(other) (ready-for-human)" "$(arg 0 --body | head -n 1)"
has "a processing order (#437)" "다른 지시를 기다리지 않고" "$(arg 0 --body)"
for step in "1. 원인 확인" "2. 고침" "3. 재발 방지 장치" "4. 결과 보고"; do has "step $step" "$step" "$(arg 0 --body)"; done
eq profile automation "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"
eq state "label 301 ready-for-human 2026-11-18T01:00:00Z test/coord" "$(state)"

setup "a deferred issue left with ready-for-human is not mailed (#437)"
issue 301 open ready-for-human,deferred "미룬 티켓"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

setup "a deferred blocker marker is mailed as 공장 막힘(미룸) with its own what to do (#437)"
issue 900 open factory-ledger "장부"
comment 19 900 "<!-- factory-stalled deferred-301-302 -->
공장 막힘(미룸): 미룬 #301(deferred)이 #302을 막는다."
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
has subject "공장 막힘(미룸)" "$(arg 0 --subject)"
has todo "deferred를 붙이고" "$(arg 0 --body)"

setup "the same state run again sends nothing"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"

setup "taking the label off and putting it on again is one new mail"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
unlabel 301 ready-for-human
run
eq "off: nothing" 1 "$(sent_count)"
relabel 301 ready-for-human
labeled 301 ready-for-human 2026-11-19T05:00:00Z
run
eq "on again: one more" 2 "$(sent_count)"
has "new key" "2026-11-19T05-00-00Z" "$(arg 1 --idempotency-key)"
run
eq "and only once" 2 "$(sent_count)"

setup "human-check with no unchecked item sends nothing; with one it is sent"
issue 310 open human-check "확인 끝남" "- [x] 창 확인
- [x] 한글 확인"
labeled 310 human-check 2026-11-18T01:00:00Z
issue 311 open human-check "확인 남음" "본문
- [x] 창 확인
- [ ] 한글 확인"
labeled 311 human-check 2026-11-18T02:00:00Z
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq subject "[facet 공장] 사람 확인: #311 확인 남음" "$(arg 0 --subject)"

setup "queue done and no ticket: idle is sent once"
issue 249 closed spec "공장 개선"
issue 250 closed spec "검색"
issue 260 closed ready-for-agent "끝난 티켓"
export FACTORY_SPEC_QUEUE="249 250"
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq to test/coord "$(arg 0 --to)"
eq key facet-factory-idle-249-250-test-coord "$(arg 0 --idempotency-key)"
has subject "공장 idle" "$(arg 0 --subject)"
run
eq "once per queue" 1 "$(sent_count)"
export FACTORY_SPEC_QUEUE="249,250 251"
issue 251 closed spec "다음"
run
eq "a new queue value is a new mail" 2 "$(sent_count)"

setup "idle is not sent while a queue spec is open or a ticket waits"
issue 249 closed spec "공장 개선"
issue 250 open spec "검색"
export FACTORY_SPEC_QUEUE="249 250"
run
eq "open spec" 0 "$(sent_count)"
issue 250 closed spec "검색"
issue 270 open in-progress "도는 티켓"
run
eq "running ticket" 0 "$(sent_count)"
issue 270 closed in-progress "도는 티켓"
issue 271 open ready-for-agent "기다리는 티켓"
run
eq "waiting ticket" 0 "$(sent_count)"
eq code 0 "$(code)"

setup "an idle marker and the direct idle check of the same queue send one mail"
issue 249 closed spec "공장 개선"
issue 900 open factory-ledger "장부"
export FACTORY_SPEC_QUEUE="249"
comment 21 900 "<!-- factory-idle 249 -->
공장 idle"
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq key facet-factory-idle-249-test-coord "$(arg 0 --idempotency-key)"

# --- recipients ------------------------------------------------------------------------------------

setup "needs-decision goes to the boss only; the other labels to the coordinator and every BRIDGE_CC"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 250 open spec,factory-paused "검색"
labeled 250 factory-paused 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
export BRIDGE_CC="test/cc1, test/cc2,,"
run
eq code 0 "$(code)"
eq tos "test/boss test/coord test/cc1 test/cc2 test/coord test/cc1 test/cc2" "$(tos)"
eq "question subject" "[facet 공장] 질문: #249 공장 개선" "$(arg 0 --subject)"
eq "cc key" "facet-factory-label-301-ready-for-human-2026-11-18T01-00-00Z-test-cc1" "$(arg 2 --idempotency-key)"
eq "cc gets one line (#437)" "사람 넘김(other) #301 티켓 하나" "$(arg 2 --body)"
eq "cc subject carries the code" "[facet 공장] 사람 넘김(other): #301 티켓 하나" "$(arg 2 --subject)"
has "coordinator gets the order" "할 일 — 이 메일이 처리 지시다" "$(arg 1 --body)"
eq "the question is unchanged: no processing order" no \
  "$(case "$(arg 0 --body)" in *"처리 지시"*) echo yes ;; *) echo no ;; esac)"
run
eq "not again" 7 "$(sent_count)"

setup "a recipient added to BRIDGE_CC later gets only what still waits"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
export BRIDGE_CC=test/cc1
run
eq tos "test/coord test/cc1" "$(tos)"

setup "without BRIDGE_TO_BOSS or BRIDGE_TO_COORD nothing is read or sent and the reason is printed"
issue 301 open ready-for-human "티켓 하나"
unset BRIDGE_TO_COORD
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"
has reason "BRIDGE_TO_COORD" "$(cat "$tmp/log")"
eq "gh not called" no "$([ -s "$FAKE_GH/calls.log" ] && echo yes || echo no)"
export BRIDGE_TO_COORD=test/coord
unset BRIDGE_TO_BOSS
run
eq "boss too" 2 "$(code)"
has reason "BRIDGE_TO_BOSS" "$(cat "$tmp/log")"

setup "a leftover BRIDGE_TO is ignored with a warning"
issue 249 open needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
export BRIDGE_TO=test/old
run
eq code 0 "$(code)"
eq to test/boss "$(arg 0 --to)"
has warning "BRIDGE_TO is ignored" "$(cat "$tmp/log")"

setup "SWITCHBOARD_PROFILE is passed through"
issue 301 open ready-for-human "티켓 하나"
export SWITCHBOARD_PROFILE=custom
run
eq profile custom "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"

setup "needs-triage, needs-info, local and closed issues are not sent"
issue 401 open needs-triage "분류 전"
issue 402 open needs-info "정보 필요"
issue 403 open local "로컬"
issue 404 closed ready-for-human "닫힘"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

# --- the reason ------------------------------------------------------------------------------------

setup "the reason is the latest trusted factory marker comment, quoted"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 1 "<!-- factory-human -->
되돌림 두 번" "github-actions[bot]" 2026-11-17T01:00:00Z
icomment 301 2 "<!-- factory-human -->
최신 까닭" "github-actions[bot]" 2026-11-17T02:00:00Z
icomment 301 3 "<!-- factory-human -->
가짜 까닭" "stranger" 2026-11-17T03:00:00Z
icomment 301 4 "그냥 댓글" "github-actions[bot]" 2026-11-17T04:00:00Z
run
eq code 0 "$(code)"
has quote "> 최신 까닭" "$(arg 0 --body)"
case "$(arg 0 --body)" in *"가짜 까닭"*|*"그냥 댓글"*|*"되돌림 두 번"*) bad "only the latest trusted marker" ;; *) ok ;; esac

setup "the hand-over code of the latest trusted marker is in the subject and first line (#437)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 1 "<!-- factory-human conflict -->
main과 충돌" "github-actions[bot]" 2026-11-17T01:00:00Z
icomment 301 2 "<!-- factory-human push-rejected -->
push 거절" "github-actions[bot]" 2026-11-17T02:00:00Z
icomment 301 3 "<!-- factory-human workflow-change -->
가짜" "stranger" 2026-11-17T03:00:00Z
run
eq subject "[facet 공장] 사람 넘김(push-rejected): #301 티켓 하나" "$(arg 0 --subject)"
eq "first line" "종류: 사람 넘김(push-rejected) (ready-for-human)" "$(arg 0 --body | head -n 1)"
has quote "> push 거절" "$(arg 0 --body)"

setup "an old marker without a code already mailed is not sent again (#437)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 1 "<!-- factory-human -->
옛 표지" "github-actions[bot]" 2026-11-17T01:00:00Z
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
echo "label 301 ready-for-human 2026-11-18T01:00:00Z test/coord" > "$XDG_STATE_HOME/facet-factory-bridge/sent"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

setup "a label is sent even when every marker comment is by someone without write access"
issue 301 open ready-for-human "티켓 하나"
icomment 301 3 "<!-- factory-human -->
가짜 까닭" "stranger"
run
eq sends 1 "$(sent_count)"
has body "까닭 댓글 없음" "$(arg 0 --body)"

# --- marker comments -------------------------------------------------------------------------------

markers() {
  issue 900 open factory-ledger "장부"
  issue 901 open bench-alert "벤치"
  comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->
하루 상한"
  comment 14 900 "<!-- factory-queue-empty 250 -->
마지막 spec"
  comment 15 900 "<!-- factory-stalled 2026-11-18 -->
- #301(ready-for-human)이 #302을 막는다"
  comment 16 901 "<!-- factory-bench-regression abc123 -->
search 한도 초과"
  comment 17 900 "그냥 댓글"
  comment 18 900 "<!-- factory-question -->
옛 질문 표지(라벨이 맡는다)"
}

setup "each marker comment is mailed once to the coordinator with its kind and what to do"
markers
run
eq code 0 "$(code)"
eq sends 4 "$(sent_count)"
eq tos "test/coord test/coord test/coord test/coord" "$(tos)"
eq key facet-factory-13 "$(arg 0 --idempotency-key)"
eq subject "[facet 공장] 하루 상한 멈춤: #900 장부" "$(arg 0 --subject)"
has "queue-empty" "spec 큐 바닥남" "$(arg 1 --subject)"
has "stalled" "공장 막힘" "$(arg 2 --subject)"
has "stalled body" "#301(ready-for-human)이 #302을 막는다" "$(arg 2 --body)"
has "bench" "벤치 한도 초과" "$(arg 3 --subject)"
has "link" "https://github.com/owner/repo/issues/900#issuecomment-13" "$(arg 0 --body)"
eq state "13
14
15
16" "$(state)"
run
eq "not again" 4 "$(sent_count)"

setup "marker comments are copied to every BRIDGE_CC"
markers
export BRIDGE_CC=test/cc1
run
eq sends 8 "$(sent_count)"
eq "cc key" facet-factory-13-test-cc1 "$(arg 1 --idempotency-key)"
has "cc state" "13 test/cc1" "$(state)"

setup "a comment sent to the coordinator before #410 (bare id) is not sent to it again"
markers
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14\n15\n16\n' > "$XDG_STATE_HOME/facet-factory-bridge/sent"
run
eq sends 0 "$(sent_count)"

setup "a marker by someone without write access is not sent and not looked at again"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->" stranger
export BRIDGE_CC=test/cc1
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
has state "13 ignored" "$(state)"
: > "$FAKE_GH/calls.log"
run
case "$(cat "$FAKE_GH/calls.log")" in *collaborators*) bad "permission asked again" ;; *) ok ;; esac

setup "markers by write, maintain and admin collaborators are sent; triage is not"
issue 900 open factory-ledger "장부"
for p in write maintain admin triage; do
  echo "{\"permission\": \"$p\", \"role_name\": \"$p\"}" > "$FAKE_GH/permission-u$p.json"
done
comment 31 900 "<!-- factory-queue-empty 1 -->" uwrite
comment 32 900 "<!-- factory-queue-empty 2 -->" umaintain
comment 33 900 "<!-- factory-queue-empty 3 -->" uadmin
comment 34 900 "<!-- factory-queue-empty 4 -->" utriage
run
eq sends 3 "$(sent_count)"

setup "a permission that cannot be read is retried next run"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->" someone
echo '{"permission": "write", "role_name": "write"}' > "$FAKE_GH/permission-someone.json"
touch "$FAKE_GH/fail-permission"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
rm "$FAKE_GH/fail-permission"
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"

setup "a failed send is not remembered and is retried next time"
issue 301 open ready-for-human "티켓 하나"
markers
touch "$FAKE_MAIL/fail"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
rm "$FAKE_MAIL/fail"
run
eq code 0 "$(code)"
eq sends 5 "$(sent_count)"

# --- --seed ----------------------------------------------------------------------------------------

setup "--seed remembers labels as they are now, marker comments and idle without sending"
issue 249 open needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 250 closed spec "검색"
markers
comment 40 900 "<!-- factory-stalled 2026-11-18 -->" stranger
export FACTORY_SPEC_QUEUE=250 BRIDGE_CC=test/cc1
run --seed
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
has "label line" "label 301 ready-for-human 2026-11-18T01:00:00Z test/cc1" "$(state)"
has "idle line" "idle 250 test/coord" "$(state)"
has "ignored line" "40 ignored" "$(state)"
run
eq "nothing after seed" 0 "$(sent_count)"
unlabel 301 ready-for-human; relabel 301 ready-for-human
labeled 301 ready-for-human 2026-11-19T05:00:00Z
run
eq "a label put on after the seed is sent" 2 "$(sent_count)"

# --- repository name (#380) ------------------------------------------------------------------------

setup "FACTORY_REPO=owner/other names the task, key, subject and state folder after other"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
export FACTORY_REPO=owner/other
run
eq code 0 "$(code)"
eq task other-factory "$(arg 0 --task)"
has key "other-factory-label-301" "$(arg 0 --idempotency-key)"
eq subject "[other 공장] 사람 넘김(other): #301 티켓 하나" "$(arg 0 --subject)"
eq "state folder" other-factory-bridge "$(ls "$XDG_STATE_HOME" | tr -d '\r')"
has "gh reads other" "repos/owner/other/issues" "$(cat "$FAKE_GH/calls.log")"

setup "BRIDGE_STATE_DIR is the state folder"
issue 301 open ready-for-human "티켓 하나"
export BRIDGE_STATE_DIR="$tmp/custom state"
run
eq code 0 "$(code)"
has "state file" "label 301 ready-for-human" "$(cat "$tmp/custom state/sent")"
eq "nothing under XDG_STATE_HOME" no "$([ -e "$XDG_STATE_HOME" ] && echo yes || echo no)"
run
eq "not again" 1 "$(sent_count)"

setup "without FACTORY_REPO the repository is the GitHub origin of the checkout holding the script (#437)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
unset FACTORY_REPO
git init -q "$tmp/copy" && git -C "$tmp/copy" remote add origin https://github.com/acme/widget.git
cp "$script" "$tmp/copy/bridge.sh"
( cd "$tmp" && bash "$tmp/copy/bridge.sh" > "$tmp/log" 2>&1; echo $? > "$tmp/code" )
eq code 0 "$(code)"
eq task widget-factory "$(arg 0 --task)"
has "gh reads it" "repos/acme/widget/issues" "$(cat "$FAKE_GH/calls.log")"
git -C "$tmp/copy" remote set-url origin git@github.com:acme/gadget.git
rm -f "$FAKE_MAIL/sent.jsonl"
( cd "$tmp" && FACTORY_REPO= bash "$tmp/copy/bridge.sh" > "$tmp/log" 2>&1 )
has "ssh remote too" "repos/acme/gadget/issues" "$(cat "$FAKE_GH/calls.log")"

setup "without FACTORY_REPO or a GitHub origin the bridge stops with exit 2 (#437)"
unset FACTORY_REPO
mkdir -p "$tmp/bare"
cp "$script" "$tmp/bare/bridge.sh"
( cd "$tmp/bare" && GIT_CEILING_DIRECTORIES="$tmp" bash "$tmp/bare/bridge.sh" > "$tmp/log" 2>&1; echo $? > "$tmp/code" )
eq code 2 "$(code)"
has reason "FACTORY_REPO" "$(cat "$tmp/log")"
eq sends 0 "$(sent_count)"

# --- #492: the kit shared by more repositories --------------------------------------------------------

setup "a marker comment by a BRIDGE_TRUSTED_BOTS login is sent without a permission lookup (#492)"
issue 900 open factory-ledger "장부"
comment 51 900 "<!-- factory-stalled 2026-11-18 -->" "example-bot[bot]"
comment 52 900 "<!-- factory-stalled 2026-11-19 -->" "other-bot[bot]"
export BRIDGE_TRUSTED_BOTS="example-bot[bot], helper-bot[bot]"
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
has "trusted bot's comment" "issuecomment-51" "$(arg 0 --body)"
has "the other bot is not trusted" "52 ignored" "$(state)"
case "$(cat "$FAKE_GH/calls.log")" in *"collaborators/example-bot"*) bad "permission asked for a trusted bot" ;; *) ok ;; esac

setup "without BRIDGE_TRUSTED_BOTS a bot that is not github-actions[bot] is not trusted (#492)"
issue 900 open factory-ledger "장부"
comment 51 900 "<!-- factory-stalled 2026-11-18 -->" "example-bot[bot]"
run
eq sends 0 "$(sent_count)"

setup "a ready-for-human reason by a BRIDGE_TRUSTED_BOTS login is quoted (#492)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 71 "<!-- factory-human conflict -->
충돌이 풀리지 않는다" "example-bot[bot]"
export BRIDGE_TRUSTED_BOTS="example-bot[bot]"
run
has "reason quoted" "충돌이 풀리지 않는다" "$(arg 0 --body)"
eq subject "[facet 공장] 사람 넘김(conflict): #301 티켓 하나" "$(arg 0 --subject)"

setup "human-check goes to the coordinator by default with the check order (#492)"
issue 311 open human-check "확인 남음" "- [ ] 한글 확인"
labeled 311 human-check 2026-11-18T02:00:00Z
export BRIDGE_CC=test/cc1
run
eq tos "test/coord test/cc1" "$(tos)"
has "todo" "미체크 항목을 손으로 확인해 체크한다" "$(arg 0 --body)"
has "next spec" "공장이 다음 spec으로 간다" "$(arg 0 --body)"

setup "BRIDGE_HUMAN_CHECK_TO=boss sends human-check to the owner alone, as a plain mail (#492)"
issue 311 open human-check "확인 남음" "- [ ] 한글 확인"
labeled 311 human-check 2026-11-18T02:00:00Z
issue 900 open factory-ledger "장부"
comment 61 900 "<!-- factory-human-check 250 -->
확인 이슈 #311"
export BRIDGE_CC=test/cc1 BRIDGE_HUMAN_CHECK_TO=boss
run
eq code 0 "$(code)"
eq tos "test/boss test/boss" "$(tos)"
eq subject "[facet 공장] 사람 확인: #311 확인 남음" "$(arg 0 --subject)"
eq "no processing order" no "$(case "$(arg 0 --body)" in *"처리 지시"*) echo yes ;; *) echo no ;; esac)"
has "marker kind" "사람 확인" "$(arg 1 --subject)"
has "marker todo" "미체크 항목을 손으로 확인해 체크한다" "$(arg 1 --body)"
run
eq "not again" 2 "$(sent_count)"

setup "the factory-human-check marker goes to the coordinator and BRIDGE_CC by default (#492)"
issue 900 open factory-ledger "장부"
comment 61 900 "<!-- factory-human-check 250 -->"
export BRIDGE_CC=test/cc1
run
eq tos "test/coord test/cc1" "$(tos)"

setup "BRIDGE_HUMAN_CHECK_TO other than boss or coord stops with exit 2 (#492)"
export BRIDGE_HUMAN_CHECK_TO=everyone
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"

setup "human-check counts unchecked items with indents and * or + bullets (#492)"
issue 312 open human-check "별표" "  * [ ] 들여쓴 별표"
labeled 312 human-check 2026-11-18T02:00:00Z
issue 313 open human-check "더하기" "+ [ ] 더하기"
labeled 313 human-check 2026-11-18T02:00:00Z
issue 314 open human-check "체크 아님" "- [x] 끝
[ ] 글머리 없음"
labeled 314 human-check 2026-11-18T02:00:00Z
run
eq sends 2 "$(sent_count)"

setup "ready-for-human with local is mailed as 로컬 작업자 몫 (#492)"
issue 320 open ready-for-human,local "워크플로 고침"
labeled 320 ready-for-human 2026-11-18T01:00:00Z
export BRIDGE_CC=test/cc1
run
eq tos "test/coord test/cc1" "$(tos)"
eq subject "[facet 공장] 로컬 작업자 몫: #320 워크플로 고침" "$(arg 0 --subject)"
has "local todo" "로컬 작업자가 구현한다" "$(arg 0 --body)"
eq "cc line" "로컬 작업자 몫 #320 워크플로 고침" "$(arg 1 --body)"

setup "BRIDGE_CC splits on spaces and tabs and drops repeats and the coordinator (#492)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
export BRIDGE_CC="test/cc1 test/cc2	test/cc1,test/coord , "
run
eq tos "test/coord test/cc1 test/cc2" "$(tos)"

setup "--seed after a bridge that kept bare ids sends no copy to BRIDGE_CC later (#492)"
markers
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14\n15\n16\n' > "$XDG_STATE_HOME/facet-factory-bridge/sent"
export BRIDGE_CC=test/cc1
run --seed
eq "seed sends nothing" 0 "$(sent_count)"
run
eq "no cc copy afterwards" 0 "$(sent_count)"
has "cc remembered" "13 test/cc1" "$(state)"

setup "every old state line form is read without sending again (#492)"
markers
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 250 closed spec "검색"
export FACTORY_SPEC_QUEUE=250
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14 test/coord\n15 ignored\n16\nlabel 301 ready-for-human 2026-11-18T01:00:00Z test/coord\nidle 250 test/coord\nlabels-seeded\n' \
  > "$XDG_STATE_HOME/facet-factory-bridge/sent"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

echo "bridge.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
