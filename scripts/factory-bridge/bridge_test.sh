#!/usr/bin/env bash
# Tests of scripts/factory-bridge/bridge.sh (labels and marker comments → Orca mail, #410, #257) against
# the fake gh (.github/factory/tests/fake/gh) and orca (fake/orca here). The notify config and the
# terminals are made up (term_coord, test-server, bot:test-boss).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/bridge.sh"
export PATH="$here/fake:$here/../../.github/factory/tests/fake:$PATH"

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FAKE_ORCA="$tmp/orca" XDG_STATE_HOME="$tmp/state"
  export BRIDGE_SINCE=2026-11-01T00:00:00Z
  unset BRIDGE_STATE_DIR BRIDGE_TO BRIDGE_TO_BOSS BRIDGE_TO_COORD BRIDGE_CC FACTORY_SPEC_QUEUE BRIDGE_TRUSTED_BOTS \
    BRIDGE_HUMAN_CHECK_TO XDG_CONFIG_HOME
  export FACTORY_REPO=owner/facet # the copy of this kit in any repository passes these tests as is (#437)
  export BRIDGE_NOTIFY_ENV="$tmp/notify.env"
  mkdir -p "$FAKE_GH" "$FAKE_ORCA"
  echo '[]' > "$FAKE_GH/repo-comments.json"
  notify_env
  coord_open
}

# notify_env [KEY=value …]: the notify config with every key, and the extra lines given. Written in each
# form the bridge reads (plain, quoted, export, comments, blank lines).
notify_env() {
  { echo "# notify config"
    echo "BRIDGE_COORD_WORKTREE=$tmp/coord dir"
    echo 'BRIDGE_COORD_TITLE="coordinator"'
    echo ""
    echo "export BRIDGE_BOSS_ON=test-server"
    echo "BRIDGE_BOSS_TO='bot:test-boss'"
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$BRIDGE_NOTIFY_ENV"
}

# coord_open: the coordinator terminal is open (with a terminal of the same title in another folder and
# another terminal in its folder). coord_closed: it is not.
coord_open() {
  jq -n --arg d "$tmp" '[{worktree: "\($d)/other", title: "coordinator", handle: "term_other"},
    {worktree: "\($d)/coord dir", title: "shell", handle: "term_shell"},
    {worktree: "\($d)/coord dir", title: "coordinator", handle: "term_coord"}]' > "$FAKE_ORCA/terminals.json"
}
coord_closed() { rm -f "$FAKE_ORCA/terminals.json"; }

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

# labeled <n> <label> <time> [actor login, default github-actions[bot]]: a `labeled` event in the
# issue's timeline
labeled() {
  local f="$FAKE_GH/timeline-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg l "$2" --arg t "$3" --arg a "${4:-github-actions[bot]}" \
    '. + [{event: "labeled", created_at: $t, label: {name: $l}, actor: {login: $a}}]' "$f" \
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
sent_count() { [ -f "$FAKE_ORCA/sent.jsonl" ] && wc -l < "$FAKE_ORCA/sent.jsonl" | tr -d ' ' || echo 0; }
# arg <send index from 0> <option>: the value after the option in that send (empty without it); --body is
# the text read from --body-file -
arg() {
  jq -s -r --argjson i "$1" --arg o "$2" 'if $o == "--body" then .[$i].body
    else .[$i].args as $a | ($a | index($o)) as $k | if $k == null then "" else $a[$k + 1] end end' \
    "$FAKE_ORCA/sent.jsonl" | tr -d '\r'
}
# tos: every send's logical recipient, space-separated. coord is --to term_coord without --on; boss is
# --on test-server --to bot:test-boss; anything else shows as ?<to>. Every send must be --from term_coord.
tos() {
  jq -s -r '[.[].args as $a | ($a | index("--to")) as $t | ($a | index("--on")) as $on
    | ($a | index("--from")) as $f
    | if $f == null or $a[$f + 1] != "term_coord" then "?from"
      elif $on == null and $a[$t + 1] == "term_coord" then "coord"
      elif $on != null and $a[$on + 1] == "test-server" and $a[$t + 1] == "bot:test-boss" then "boss"
      else "?\($a[$t + 1])" end] | join(" ")' "$FAKE_ORCA/sent.jsonl" 2> /dev/null | tr -d '\r'
}
# noleak: the log names no address, handle or folder of the notify config
noleak() {
  case "$(cat "$tmp/log")" in
    *term_coord* | *test-server* | *bot:test-boss* | *"coord dir"*) bad "the log names a recipient value" ;;
    *) ok ;;
  esac
}
state() { tr -d '\r' < "$XDG_STATE_HOME/facet-factory-bridge/sent"; }

# --- labels (#410 더함 2, 14번) ----------------------------------------------------------------------

setup "ready-for-human without any marker comment is sent once, saying there is no reason comment"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq to coord "$(tos)"
eq type status "$(arg 0 --type)"
eq "body on stdin" - "$(arg 0 --body-file)"
eq subject "[facet 공장] 사람 넘김(other): #301 티켓 하나" "$(arg 0 --subject)"
has body "까닭 댓글 없음" "$(arg 0 --body)"
has "body link" "https://github.com/owner/repo/issues/301" "$(arg 0 --body)"
eq "first line names the code (#437)" "종류: 사람 넘김(other) (ready-for-human)" "$(arg 0 --body | head -n 1)"
has "a processing order (#437)" "다른 지시를 기다리지 않고" "$(arg 0 --body)"
for step in "1. 원인 확인" "2. 고침" "3. 재발 방지 장치" "4. 결과 보고"; do has "step $step" "$step" "$(arg 0 --body)"; done
noleak
eq state "label 301 ready-for-human 2026-11-18T01:00:00Z coord" "$(state)"

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
has "new state line" "label 301 ready-for-human 2026-11-19T05:00:00Z coord" "$(state)"
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
eq to coord "$(tos)"
has state "idle 249-250 coord" "$(state)"
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
has state "idle 249 coord" "$(state)"

# --- recipients ------------------------------------------------------------------------------------

setup "needs-decision goes to the boss only; the other labels to the coordinator and every BRIDGE_CC"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 250 open spec,factory-paused "검색"
labeled 250 factory-paused 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
export BRIDGE_CC="boss,,"
run
eq code 0 "$(code)"
eq tos "boss coord boss coord boss" "$(tos)"
eq "question subject" "[facet 공장] 질문: #249 공장 개선" "$(arg 0 --subject)"
has "cc state" "label 301 ready-for-human 2026-11-18T01:00:00Z boss" "$(state)"
eq "cc gets one line (#437)" "사람 넘김(other) #301 티켓 하나" "$(arg 2 --body)"
eq "cc subject carries the code" "[facet 공장] 사람 넘김(other): #301 티켓 하나" "$(arg 2 --subject)"
has "coordinator gets the order" "할 일 — 이 메일이 처리 지시다" "$(arg 1 --body)"
eq "the question is unchanged: no processing order" no \
  "$(case "$(arg 0 --body)" in *"처리 지시"*) echo yes ;; *) echo no ;; esac)"
run
eq "not again" 5 "$(sent_count)"

setup "a recipient added to BRIDGE_CC later gets only what still waits"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
export BRIDGE_CC=boss
run
eq tos "coord boss" "$(tos)"

setup "without the notify config nothing is read or sent and exit is 2"
issue 301 open ready-for-human "티켓 하나"
export BRIDGE_NOTIFY_ENV="$tmp/none.env"
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"
has reason "notify config is missing" "$(cat "$tmp/log")"
eq "gh not called" no "$([ -s "$FAKE_GH/calls.log" ] && echo yes || echo no)"
eq "orca not called" no "$([ -s "$FAKE_ORCA/calls.log" ] && echo yes || echo no)"

setup "an empty key of the notify config is named, without any value, and exit is 2"
issue 301 open ready-for-human "티켓 하나"
notify_env "BRIDGE_COORD_TITLE=" "BRIDGE_BOSS_TO="
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"
has reason "no value for BRIDGE_COORD_TITLE BRIDGE_BOSS_TO" "$(cat "$tmp/log")"
noleak
eq "gh not called" no "$([ -s "$FAKE_GH/calls.log" ] && echo yes || echo no)"
grep -v BRIDGE_BOSS_ON "$BRIDGE_NOTIFY_ENV" > "$tmp/n" && mv "$tmp/n" "$BRIDGE_NOTIFY_ENV"
run
eq "a key left out too" 2 "$(code)"
has reason "BRIDGE_BOSS_ON" "$(cat "$tmp/log")"

setup "the default notify config is <XDG_CONFIG_HOME>/<name>-factory-bridge/bridge-notify.env"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
mkdir -p "$tmp/config/facet-factory-bridge"
mv "$BRIDGE_NOTIFY_ENV" "$tmp/config/facet-factory-bridge/bridge-notify.env"
unset BRIDGE_NOTIFY_ENV
export XDG_CONFIG_HOME="$tmp/config"
run
eq code 0 "$(code)"
eq tos coord "$(tos)"

setup "BRIDGE_CC with anything but coord and boss stops with exit 2, naming no value"
issue 301 open ready-for-human "티켓 하나"
export BRIDGE_CC="boss, someone/else"
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"
has reason "coord and boss only" "$(cat "$tmp/log")"
eq "no value" no "$(case "$(cat "$tmp/log")" in *someone*) echo yes ;; *) echo no ;; esac)"

# --- Orca mail -------------------------------------------------------------------------------------

setup "every kind goes to its Orca address, from the coordinator terminal of the configured folder and title"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 311 open human-check "확인 남음" "- [ ] 한글 확인"
labeled 311 human-check 2026-11-18T02:00:00Z
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->"
run
eq code 0 "$(code)"
eq "needs-decision boss; ready-for-human, human-check and a marker coord" "boss coord coord coord" "$(tos)"
eq "boss server" test-server "$(arg 0 --on)"
eq "boss bot" bot:test-boss "$(arg 0 --to)"
eq "coord to its own handle" term_coord "$(arg 1 --to)"
eq "no server for coord" "" "$(arg 1 --on)"
eq "status mail" "status status status status" "$(for i in 0 1 2 3; do arg $i --type; done | tr '\n' ' ' | sed 's/ $//')"
has "terminal looked up by folder" "terminal list --worktree path:$tmp/coord dir --json" "$(cat "$FAKE_ORCA/calls.log")"
eq "looked up once a run" 1 "$(grep -c '^terminal list' "$FAKE_ORCA/calls.log")"
noleak

setup "without the coordinator terminal nothing is sent or remembered, and the next run sends it"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->"
export BRIDGE_CC=boss
coord_closed
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
eq "nothing remembered" "" "$(state)"
has reason "coordinator terminal is not open" "$(cat "$tmp/log")"
has "will retry" "will retry" "$(cat "$tmp/log")"
eq "no send tried without a sender" no "$(grep -q '^orchestration send' "$FAKE_ORCA/calls.log" && echo yes || echo no)"
noleak
touch "$FAKE_ORCA/fail-list"
coord_open
run
eq "a failing terminal list is the same" 1 "$(code)"
eq "still nothing" 0 "$(sent_count)"
rm "$FAKE_ORCA/fail-list"
run
eq code 0 "$(code)"
eq "everything once" "boss coord boss coord boss" "$(tos)"
run
eq "and not again" 5 "$(sent_count)"

setup "a terminal with another title is not the coordinator"
issue 301 open ready-for-human "티켓 하나"
notify_env "BRIDGE_COORD_TITLE=nobody"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"

setup "a leftover BRIDGE_TO is ignored with a warning"
issue 249 open needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
export BRIDGE_TO=test/old BRIDGE_TO_BOSS=test/old-boss BRIDGE_TO_COORD=test/old-coord
run
eq code 0 "$(code)"
eq to boss "$(tos)"
has warning "BRIDGE_TO is ignored" "$(cat "$tmp/log")"
has warning "BRIDGE_TO_BOSS is ignored" "$(cat "$tmp/log")"
has warning "BRIDGE_TO_COORD is ignored" "$(cat "$tmp/log")"

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
echo "label 301 ready-for-human 2026-11-18T01:00:00Z coord" > "$XDG_STATE_HOME/facet-factory-bridge/sent"
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

setup "factory-paused and ready-for-human put on by a person are not mailed; by a bot they are (#502)"
issue 250 open spec,factory-paused "검색"
labeled 250 factory-paused 2026-11-19T03:41:28Z someone
issue 301 open ready-for-human "손으로 맡은 티켓"
labeled 301 ready-for-human 2026-11-19T03:51:30Z someone
issue 302 open ready-for-human "앱 봇이 넘긴 티켓"
labeled 302 ready-for-human 2026-11-19T04:00:00Z test-bot[bot]
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-19T04:00:00Z someone
export BRIDGE_TRUSTED_BOTS=test-bot[bot]
run
eq code 0 "$(code)"
eq "the bot's hand-over and the person's question only" "boss coord" "$(tos)"
has "the bot's hand-over is #302" "#302" "$(arg 1 --subject)"
has "status line for the paused spec" "not mailing factory-paused #250: put on by someone" "$(cat "$tmp/log")"
has "status line for the hand-over" "not mailing ready-for-human #301: put on by someone" "$(cat "$tmp/log")"
has "remembered" "label 250 factory-paused 2026-11-19T03:41:28Z human" "$(state)"
run
eq "not again" 2 "$(sent_count)"
eq "the status line once" no "$(case "$(cat "$tmp/log")" in *"not mailing"*) echo yes ;; *) echo no ;; esac)"
unlabel 250 factory-paused
relabel 250 factory-paused
labeled 250 factory-paused 2026-11-19T05:00:00Z
run
eq "put on again by the factory: mailed" 3 "$(sent_count)"
has "spec stop" "spec 상한 멈춤: #250" "$(arg 2 --subject)"

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
eq tos "coord coord coord coord" "$(tos)"
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

setup "a daily budget of 0 is mailed as a stop on purpose, without the midnight sentence (#502)"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-19 -->
하루 상한에 닿아 공장이 멈췄다: 2026-11-19(KST) 합계 \$0 / 상한 \$0. KST 0시가 지나면 예약 실행이 다시 시작한다."
comment 14 900 "<!-- factory-budget-daily 2026-11-18 -->
하루 상한에 닿아 공장이 멈췄다: 2026-11-18(KST) 합계 \$150 / 상한 \$150. KST 0시가 지나면 예약 실행이 다시 시작한다."
run
eq code 0 "$(code)"
eq sends 2 "$(sent_count)"
eq "cap 0 subject" "[facet 공장] 하루 상한 0(멈춤): #900 장부" "$(arg 0 --subject)"
eq "no midnight for cap 0" no "$(case "$(arg 0 --body)" in *"0시"*) echo yes ;; *) echo no ;; esac)"
has "what to do for cap 0" "상한 0: 일부러 멈춘 상태다" "$(arg 0 --body)"
has "a cap above 0 still waits for midnight" "KST 0시가 지나면 공장이 스스로 다시 돈다" "$(arg 1 --body)"

setup "marker comments are copied to every BRIDGE_CC"
markers
export BRIDGE_CC=boss
run
eq sends 8 "$(sent_count)"
eq "cc" "coord boss" "$(tos | cut -d" " -f1-2)"
has "cc state" "13 boss" "$(state)"

setup "a comment sent to the coordinator before #410 (bare id) is not sent to it again"
markers
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14\n15\n16\n' > "$XDG_STATE_HOME/facet-factory-bridge/sent"
run
eq sends 0 "$(sent_count)"

setup "a marker by someone without write access is not sent and not looked at again"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->" stranger
export BRIDGE_CC=boss
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
touch "$FAKE_ORCA/fail"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
rm "$FAKE_ORCA/fail"
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
export FACTORY_SPEC_QUEUE=250 BRIDGE_CC=boss
run --seed
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
has "label line" "label 301 ready-for-human 2026-11-18T01:00:00Z boss" "$(state)"
has "idle line" "idle 250 coord" "$(state)"
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
has subject "[widget 공장]" "$(arg 0 --subject)"
has "gh reads it" "repos/acme/widget/issues" "$(cat "$FAKE_GH/calls.log")"
git -C "$tmp/copy" remote set-url origin git@github.com:acme/gadget.git
rm -f "$FAKE_ORCA/sent.jsonl"
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
export BRIDGE_CC=boss
run
eq tos "coord boss" "$(tos)"
has "todo" "미체크 항목을 손으로 확인해 체크한다" "$(arg 0 --body)"
has "next spec" "공장이 다음 spec으로 간다" "$(arg 0 --body)"

setup "BRIDGE_HUMAN_CHECK_TO=boss sends human-check to the owner alone, as a plain mail (#492)"
issue 311 open human-check "확인 남음" "- [ ] 한글 확인"
labeled 311 human-check 2026-11-18T02:00:00Z
issue 900 open factory-ledger "장부"
comment 61 900 "<!-- factory-human-check 250 -->
확인 이슈 #311"
export BRIDGE_CC=boss BRIDGE_HUMAN_CHECK_TO=boss
run
eq code 0 "$(code)"
eq tos "boss boss" "$(tos)"
eq subject "[facet 공장] 사람 확인: #311 확인 남음" "$(arg 0 --subject)"
eq "no processing order" no "$(case "$(arg 0 --body)" in *"처리 지시"*) echo yes ;; *) echo no ;; esac)"
has "marker kind" "사람 확인" "$(arg 1 --subject)"
has "marker todo" "미체크 항목을 손으로 확인해 체크한다" "$(arg 1 --body)"
run
eq "not again" 2 "$(sent_count)"

setup "the factory-human-check marker goes to the coordinator and BRIDGE_CC by default (#492)"
issue 900 open factory-ledger "장부"
comment 61 900 "<!-- factory-human-check 250 -->"
export BRIDGE_CC=boss
run
eq tos "coord boss" "$(tos)"

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
export BRIDGE_CC=boss
run
eq tos "coord boss" "$(tos)"
eq subject "[facet 공장] 로컬 작업자 몫: #320 워크플로 고침" "$(arg 0 --subject)"
has "local todo" "로컬 작업자가 구현한다" "$(arg 0 --body)"
eq "cc line" "로컬 작업자 몫 #320 워크플로 고침" "$(arg 1 --body)"

setup "BRIDGE_CC splits on spaces and tabs and drops repeats and the coordinator (#492)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
export BRIDGE_CC="boss coord	boss,coord , "
run
eq tos "coord boss" "$(tos)"

setup "--seed after a bridge that kept bare ids sends no copy to BRIDGE_CC later (#492)"
markers
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14\n15\n16\n' > "$XDG_STATE_HOME/facet-factory-bridge/sent"
export BRIDGE_CC=boss
run --seed
eq "seed sends nothing" 0 "$(sent_count)"
run
eq "no cc copy afterwards" 0 "$(sent_count)"
has "cc remembered" "13 boss" "$(state)"

setup "every old state line form is read without sending again (#492)"
markers
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 250 closed spec "검색"
export FACTORY_SPEC_QUEUE=250
mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
printf '13\n14 coord\n15 ignored\n16\nlabel 301 ready-for-human 2026-11-18T01:00:00Z coord\nidle 250 coord\nlabels-seeded\n' \
  > "$XDG_STATE_HOME/facet-factory-bridge/sent"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

# --- moving a state file of mailbox addresses to the logical recipients -------------------------------

# old_state: a state file of a bridge that mailed addresses: the coordinator old/coordinator, the owner
# old/boss (also BRIDGE_CC then), a recipient since dropped old/cc; every line form.
old_state() {
  mkdir -p "$XDG_STATE_HOME/facet-factory-bridge"
  printf '%s\n' 13 "13 old/boss" "14 old/coordinator" "14 old/boss" "15 ignored" 16 "16 old/boss" \
    "label 249 needs-decision 2026-11-18T01:00:00Z old/boss" \
    "label 301 ready-for-human 2026-11-18T01:00:00Z old/coordinator" \
    "label 301 ready-for-human 2026-11-18T01:00:00Z old/boss" \
    "label 301 ready-for-human 2026-11-18T01:00:00Z old/cc" \
    "label 250 factory-paused 2026-11-19T03:41:28Z human" \
    "idle 250 old/coordinator" "idle 250 old/boss" labels-seeded \
    > "$XDG_STATE_HOME/facet-factory-bridge/sent"
}
old_world() {
  markers
  issue 249 open needs-decision "공장 개선"
  labeled 249 needs-decision 2026-11-18T01:00:00Z
  issue 301 open ready-for-human "티켓 하나"
  labeled 301 ready-for-human 2026-11-18T01:00:00Z
  issue 250 closed spec "검색"
  export FACTORY_SPEC_QUEUE=250 BRIDGE_CC=boss
}

setup "the first run on a state file of mailbox addresses sends nothing already sent"
old_world
old_state
notify_env "BRIDGE_LEGACY_COORD=old/coordinator" "BRIDGE_LEGACY_BOSS=old/boss"
run
eq code 0 "$(code)"
eq "nothing again" 0 "$(sent_count)"
has "moved" "moved 9 state lines" "$(cat "$tmp/log")"
eq "every line form moved, the rest kept" "13
13 boss
14 coord
14 boss
15 ignored
16
16 boss
label 249 needs-decision 2026-11-18T01:00:00Z boss
label 301 ready-for-human 2026-11-18T01:00:00Z coord
label 301 ready-for-human 2026-11-18T01:00:00Z boss
label 301 ready-for-human 2026-11-18T01:00:00Z old/cc
label 250 factory-paused 2026-11-19T03:41:28Z human
idle 250 coord
idle 250 boss
labels-seeded" "$(state)"
run
eq "moved once" no "$(case "$(cat "$tmp/log")" in *moved*) echo yes ;; *) echo no ;; esac)"
eq "still nothing" 0 "$(sent_count)"
noleak

setup "the legacy keys take several names, space- or comma-separated"
old_world
old_state
notify_env "BRIDGE_LEGACY_COORD=old/x, old/coordinator" "BRIDGE_LEGACY_BOSS='old/boss old/y'"
run
eq code 0 "$(code)"
eq "nothing again" 0 "$(sent_count)"

setup "without the legacy keys the old lines are kept and do not count for coord"
old_world
old_state
run
eq code 0 "$(code)"
has "the coordinator gets the label again" "coord" "$(tos)"
has "the old lines are kept" "14 old/coordinator" "$(state)"

echo "factory-bridge/bridge_test.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
