#!/usr/bin/env bash
# Tests of .github/factory/bridge.sh (labels and marker comments → switchboard mailbox, #192) against the
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
  export FACTORY_REPO=owner/repo BRIDGE_SINCE=2026-11-01T00:00:00Z
  unset BRIDGE_STATE_DIR BRIDGE_TO BRIDGE_CC SWITCHBOARD_PROFILE FACTORY_SPEC_QUEUE
  export BRIDGE_TO_BOSS=test/boss BRIDGE_TO_COORD=test/coord
  mkdir -p "$FAKE_GH" "$FAKE_MAIL"
  : > "$FAKE_GH/calls.log"
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
lacks() { # lacks <what> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: [$2] in [$3]" ;; *) ok ;; esac
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

# unlabel / relabel <n> <label>: takes the label off / puts it on
unlabel() {
  jq --arg l "$2" '.labels |= map(select(.name != $l))' "$FAKE_GH/issue-$1.json" | tr -d '\r' \
    > "$FAKE_GH/issue-$1.json.new" && mv "$FAKE_GH/issue-$1.json.new" "$FAKE_GH/issue-$1.json"
}
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
log() { cat "$tmp/log"; }
sent_count() { [ -f "$FAKE_MAIL/sent.jsonl" ] && wc -l < "$FAKE_MAIL/sent.jsonl" | tr -d ' ' || echo 0; }
# arg <send index from 0> <option>: the value after the option in that send
arg() {
  jq -s -r --argjson i "$1" --arg o "$2" '.[$i].args as $a | ($a | index($o)) as $k | $a[$k + 1]' \
    "$FAKE_MAIL/sent.jsonl" | tr -d '\r'
}
# tos: every send's recipient, space-separated
tos() { jq -s -r '[.[].args as $a | $a[($a | index("--to")) + 1]] | join(" ")' "$FAKE_MAIL/sent.jsonl" 2> /dev/null | tr -d '\r'; }
keys() { jq -s -r '[.[].args as $a | $a[($a | index("--idempotency-key")) + 1]] | join(" ")' "$FAKE_MAIL/sent.jsonl" 2> /dev/null | tr -d '\r'; }
statef() { echo "$XDG_STATE_HOME/repo-factory-bridge/sent"; }
state() { tr -d '\r' < "$(statef)"; }
clear_mail() { rm -f "$FAKE_MAIL/sent.jsonl"; }

# --- labels (#192) ---------------------------------------------------------------------------------

setup "ready-for-human without any marker comment is sent once, saying there is no reason comment"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq to test/coord "$(arg 0 --to)"
eq task repo-factory "$(arg 0 --task)"
eq key "repo-factory-label-301-ready-for-human-2026-11-18T01-00-00Z-test-coord" "$(arg 0 --idempotency-key)"
eq subject "[repo 공장] 사람 넘김: #301 티켓 하나" "$(arg 0 --subject)"
has body "까닭 댓글 없음" "$(arg 0 --body)"
has "body link" "https://github.com/owner/repo/issues/301" "$(arg 0 --body)"
has "body reset" "factory-reset" "$(arg 0 --body)"
eq profile automation "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"
eq state "label 301 ready-for-human 2026-11-18T01:00:00Z test/coord
labels-seeded" "$(state)"

setup "the same state run again sends nothing"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run; run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq "no timeline-free extra reads" 0 "$(grep -c 'issues/301/comments' "$FAKE_GH/calls.log" | awk '{print ($1 > 1)}')"

setup "taking the label off and putting it on again is one new mail"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
unlabel 301 ready-for-human
run
eq "nothing while off" 1 "$(sent_count)"
relabel 301 ready-for-human
labeled 301 ready-for-human 2026-11-18T05:00:00Z
run
eq sends 2 "$(sent_count)"
has "new key" "2026-11-18T05-00-00Z" "$(arg 1 --idempotency-key)"
run
eq "once" 2 "$(sent_count)"

setup "human-check with no unchecked item sends nothing; with one it goes to the boss only"
export BRIDGE_CC=test/cc
issue 340 open human-check "사람 확인: spec #174" "- [x] 로그인 화면 (PR #41)"
labeled 340 human-check 2026-11-18T02:00:00Z
run
eq "all checked" 0 "$(sent_count)"
issue 340 open human-check "사람 확인: spec #174" "- [x] 로그인 화면 (PR #41)
- [ ] 터미널 (PR #42)"
run
eq sends 1 "$(sent_count)"
eq to test/boss "$(tos)"
eq subject "[repo 공장] 사람 확인: #340 사람 확인: spec #174" "$(arg 0 --subject)"

setup "needs-decision goes to the boss only; ready-for-human and factory-paused to the coordinator and every BRIDGE_CC"
export BRIDGE_CC="test/cc1, test/cc2 test/coord"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 250 open spec,factory-paused "검색"
labeled 250 factory-paused 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq tos "test/boss test/coord test/cc1 test/cc2 test/coord test/cc1 test/cc2" "$(tos)"
has "paused subject" "spec 상한 멈춤: #250" "$(jq -s -r '.[].args | join(" ")' "$FAKE_MAIL/sent.jsonl")"
has "question subject" "질문: #249" "$(arg 0 --subject)"
has "cc key" "repo-factory-label-301-ready-for-human-2026-11-18T01-00-00Z-test-cc1" "$(keys)"

setup "ready-for-human with local is a local worker's ticket (local-ticket.sh)"
export BRIDGE_CC=test/cc
issue 302 open ready-for-human,local "워크플로 티켓"
labeled 302 local 2026-11-18T01:00:00Z
labeled 302 ready-for-human 2026-11-18T01:00:01Z
icomment 302 31 "<!-- factory-human -->
<!-- factory-local -->
workflow·\`.claude/\` 파일 — 로컬 작업자 몫."
run
eq sends 2 "$(sent_count)"
eq tos "test/coord test/cc" "$(tos)"
has subject "로컬 작업자 몫: #302" "$(arg 0 --subject)"
has "reason quoted" "> workflow·" "$(arg 0 --body)"

setup "needs-triage, needs-info, local alone and closed issues are not sent"
issue 310 open needs-triage "a"; labeled 310 needs-triage 2026-11-18T01:00:00Z
issue 311 open needs-info "b"; labeled 311 needs-info 2026-11-18T01:00:00Z
issue 312 open local "c"; labeled 312 local 2026-11-18T01:00:00Z
issue 313 closed ready-for-human "d"; labeled 313 ready-for-human 2026-11-18T01:00:00Z
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

setup "the reason is the latest trusted factory marker comment, quoted"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 1 "<!-- factory-implementer-failed -->
첫 실패" "github-actions[bot]" 2026-11-17T01:00:00Z
icomment 301 2 "<!-- factory-human -->
Implementer가 3번 실패했다" "sandcorp-factory[bot]" 2026-11-17T02:00:00Z
icomment 301 3 "<!-- factory-human -->
가짜 까닭" "stranger" 2026-11-17T03:00:00Z
icomment 301 4 "그냥 댓글" "github-actions[bot]" 2026-11-17T04:00:00Z
run
has "reason" "> Implementer가 3번 실패했다" "$(arg 0 --body)"
lacks "untrusted" "가짜 까닭" "$(arg 0 --body)"
lacks "older" "첫 실패" "$(arg 0 --body)"

setup "a label is sent even when every marker comment is by someone without write access"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 3 "<!-- factory-human -->
가짜 까닭" "stranger"
run
eq sends 1 "$(sent_count)"
has body "까닭 댓글 없음" "$(arg 0 --body)"

# --- recipients --------------------------------------------------------------------------------------

setup "without BRIDGE_TO_COORD nothing is read or sent (exit 2)"
unset BRIDGE_TO_COORD
issue 301 open ready-for-human "티켓 하나"
run
eq code 2 "$(code)"
eq sends 0 "$(sent_count)"
has message "BRIDGE_TO_COORD" "$(log)"
eq "no gh call" "" "$(cat "$FAKE_GH/calls.log")"

setup "without BRIDGE_TO_BOSS the boss's mails are held and sent once it is set; the rest goes on"
unset BRIDGE_TO_BOSS
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
comment 21 340 "<!-- factory-human-check 174 -->
사람 확인 대기"
issue 340 open human-check "사람 확인: spec #174"
run
eq code 1 "$(code)"
eq tos test/coord "$(tos)"
has message "set BRIDGE_TO_BOSS" "$(log)"
lacks "question not remembered" "label 249" "$(state)"
lacks "marker not remembered" "21" "$(state)"
export BRIDGE_TO_BOSS=test/boss
run
eq code 0 "$(code)"
eq tos "test/coord test/boss test/boss" "$(tos)"

setup "a leftover BRIDGE_TO is ignored with a warning"
export BRIDGE_TO=test/old
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
run
eq to test/boss "$(tos)"
has warning "BRIDGE_TO is ignored" "$(log)"

setup "SWITCHBOARD_PROFILE is passed through"
export SWITCHBOARD_PROFILE=other
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq profile other "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"

# --- marker comments ---------------------------------------------------------------------------------

setup "budget-daily, queue-empty and idle markers go to the coordinator and CC once, with the old keys"
export BRIDGE_CC=test/cc
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->
하루 상한"
comment 14 900 "<!-- factory-queue-empty 174 -->
spec 큐 바닥남"
comment 15 900 "<!-- factory-idle 174-175 -->
공장 idle"
run
eq code 0 "$(code)"
eq tos "test/coord test/cc test/coord test/cc test/coord test/cc" "$(tos)"
eq keys "repo-factory-13 repo-factory-13-cc-test-cc repo-factory-14 repo-factory-14-cc-test-cc repo-factory-idle-174-175-test-coord repo-factory-idle-174-175-test-cc" "$(keys)"
has "daily subject" "하루 상한 멈춤: #900" "$(arg 0 --subject)"
has "body" "하루 상한" "$(arg 0 --body)"
has "comment link" "#issuecomment-13" "$(arg 0 --body)"
run
eq "once" 6 "$(sent_count)"

setup "a factory-human-check marker (spec held, #167) goes to the boss only, with the old key"
export BRIDGE_CC=test/cc
issue 340 open human-check "사람 확인: spec #174"
comment 21 340 "<!-- factory-human-check 174 -->
<!-- prs 41 -->
spec #174 의 티켓이 모두 병합됐다."
run
eq tos test/boss "$(tos)"
eq key repo-factory-21 "$(arg 0 --idempotency-key)"
has subject "사람 확인 대기: #340" "$(arg 0 --subject)"

setup "markers of a labelled wait (question, budget-spec, human, local) are only reasons, never mailed alone"
issue 249 open spec "공장 개선"
issue 301 open "" "티켓 하나"
comment 11 249 "<!-- factory-question -->
A냐 B냐"
comment 12 249 "<!-- factory-budget-spec -->
상한"
comment 13 301 "<!-- factory-human -->
넘김"
comment 14 301 "<!-- factory-local -->
로컬"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"

setup "a marker by someone without write access is not sent and not looked at again"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->" stranger
run
eq sends 0 "$(sent_count)"
eq state "labels-seeded
13" "$(state)"
run
eq "permission asked once" 1 "$(grep -c 'collaborators/stranger/permission' "$FAKE_GH/calls.log")"

setup "markers by write, maintain and admin collaborators and the factory App are sent; triage is not"
issue 900 open factory-ledger "장부"
for who in w:write m:maintain a:admin t:triage; do
  echo "{\"permission\": \"${who#*:}\", \"role_name\": \"${who#*:}\"}" > "$FAKE_GH/permission-${who%%:*}.json"
done
comment 31 900 "<!-- factory-budget-daily 1 -->" w
comment 32 900 "<!-- factory-budget-daily 2 -->" m
comment 33 900 "<!-- factory-budget-daily 3 -->" a
comment 34 900 "<!-- factory-budget-daily 4 -->" t
comment 35 900 "<!-- factory-budget-daily 5 -->" "sandcorp-factory[bot]"
run
eq keys "repo-factory-31 repo-factory-32 repo-factory-33 repo-factory-35" "$(keys)"

setup "a permission that cannot be read is retried next run"
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->" someone
touch "$FAKE_GH/fail-permission"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
rm "$FAKE_GH/fail-permission"
echo '{"permission": "write", "role_name": "write"}' > "$FAKE_GH/permission-someone.json"
run
eq sends 1 "$(sent_count)"

# --- failures ----------------------------------------------------------------------------------------

setup "a failed send is not remembered and is retried next time"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->"
touch "$FAKE_MAIL/fail"
run
eq code 1 "$(code)"
lacks "label not remembered" "label 301" "$(state)"
rm "$FAKE_MAIL/fail"
run
eq code 0 "$(code)"
eq sends 2 "$(sent_count)"

setup "a failed CC send of a marker is retried alone; the coordinator is not mailed twice"
export BRIDGE_CC=test/cc
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->"
cat > "$tmp/switchboard" << 'EOF'
#!/usr/bin/env bash
case " $* " in *" test/cc "*) exit 1 ;; esac
exec "$REAL_SB" "$@"
EOF
chmod +x "$tmp/switchboard"
REAL_SB="$here/fake/switchboard" PATH="$tmp:$PATH" run
eq code 1 "$(code)"
eq "partial" "13 test/coord" "$(grep '^13' "$(statef)")"
run
eq tos "test/coord test/cc" "$(tos)"
eq "done" "13" "$(grep -x '13' "$(statef)")"

setup "a timeline that cannot be read is retried next run"
issue 301 open ready-for-human "티켓 하나"
touch "$FAKE_GH/fail-timeline"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
rm "$FAKE_GH/fail-timeline"
run
eq sends 1 "$(sent_count)"

# --- idle seen directly ------------------------------------------------------------------------------

setup "queue done and no ticket: idle is sent once"
export FACTORY_SPEC_QUEUE="174, 175" BRIDGE_CC=test/cc
issue 174 closed spec "a"; issue 175 closed spec "b"
run
eq tos "test/coord test/cc" "$(tos)"
eq key "repo-factory-idle-174-175-test-coord" "$(arg 0 --idempotency-key)"
run
eq "once" 2 "$(sent_count)"

setup "idle is not sent while a queue spec is open or a ticket waits"
export FACTORY_SPEC_QUEUE="174 175"
issue 174 closed spec "a"; issue 175 open spec "b"
run
eq "spec open" 0 "$(sent_count)"
issue 175 closed spec "b"; issue 401 open ready-for-agent "t"
run
eq "ready-for-agent" 0 "$(sent_count)"
issue 401 open in-progress "t"
run
eq "in-progress" 0 "$(sent_count)"

setup "an idle marker and the direct idle check of the same queue send one mail"
export FACTORY_SPEC_QUEUE="174 175"
issue 174 closed spec "a"; issue 175 closed spec "b"; issue 900 open factory-ledger "장부"
comment 15 900 "<!-- factory-idle 174-175 -->"
run; run
eq sends 1 "$(sent_count)"

# --- seed and upgrading ------------------------------------------------------------------------------

setup "--seed remembers labels as they are now, marker comments and idle without sending"
export FACTORY_SPEC_QUEUE=174 BRIDGE_CC=test/cc
issue 174 closed spec "a"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
issue 900 open factory-ledger "장부"
comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->"
comment 14 900 "<!-- factory-idle 174 -->"
run --seed
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
has seeded "label 301 ready-for-human 2026-11-18T01:00:00Z test/cc" "$(state)"
run
eq "nothing after the seed" 0 "$(sent_count)"
relabel 301 needs-decision
labeled 301 needs-decision 2026-11-18T06:00:00Z
run
eq "a new wait after the seed" test/boss "$(tos)"

setup "upgrading an old state file: waits the old bridge mailed are remembered, a label it never mailed is sent"
export BRIDGE_CC=test/cc
mkdir -p "$(dirname "$(statef)")"
printf '%s\n' 11 14 "15 test/coord" > "$(statef)"
issue 249 open spec,needs-decision "공장 개선"
labeled 249 needs-decision 2026-11-18T01:00:00Z
icomment 249 11 "<!-- factory-question -->
A냐 B냐"
issue 301 open ready-for-human "넘김"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 14 "<!-- factory-human -->
되돌림 두 번"
issue 302 open ready-for-human "부분만 보냄"
labeled 302 ready-for-human 2026-11-18T01:00:00Z
icomment 302 15 "<!-- factory-human -->
cc 실패"
issue 166 open ready-for-human "구현 3회 실패"
labeled 166 ready-for-human 2026-11-18T01:00:00Z
icomment 166 16 "<!-- factory-implementer-infra-failed -->
Implementer run failed (infrastructure)"
run
eq code 0 "$(code)"
eq "only the never-mailed one" "test/coord test/cc" "$(tos)"
has "#166" "#166" "$(arg 0 --subject)"
has "remembered question" "label 249 needs-decision 2026-11-18T01:00:00Z test/boss" "$(state)"
has "remembered cc of a partial" "label 302 ready-for-human 2026-11-18T01:00:00Z test/cc" "$(state)"
has "upgraded" "labels-seeded" "$(state)"
run
eq "nothing more" 2 "$(sent_count)"
relabel 249 needs-decision
unlabel 301 ready-for-human; relabel 301 ready-for-human
labeled 301 ready-for-human 2026-11-18T07:00:00Z
run
eq "after the upgrade a new label is mailed even with an old reason" "test/coord test/cc test/coord test/cc" "$(tos)"

setup "an empty state file is not an upgrade (install with --seed)"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
icomment 301 14 "<!-- factory-human -->
넘김"
run
eq sends 1 "$(sent_count)"

setup "FACTORY_REPO=owner/other names the task, key, subject and state folder; BRIDGE_STATE_DIR moves the file"
export FACTORY_REPO=owner/other BRIDGE_STATE_DIR="$tmp/elsewhere"
issue 301 open ready-for-human "티켓 하나"
labeled 301 ready-for-human 2026-11-18T01:00:00Z
run
eq task other-factory "$(arg 0 --task)"
has subject "[other 공장]" "$(arg 0 --subject)"
has state "label 301" "$(cat "$tmp/elsewhere/sent")"

# --- the script itself --------------------------------------------------------------------------------

current="no address, token, home path or recipient name in the script"
eq "http" 0 "$(grep -c 'https\?://' "$script" || true)"
eq "home" 0 "$(grep -ci '/home/\|/Users/\|C:\\' "$script" || true)"
eq "token" 0 "$(grep -ci 'token' "$script" || true)"
eq "recipient default" 0 "$(grep -cE 'BRIDGE_TO_(BOSS|COORD):-[^}]' "$script" || true)"
eq "mailbox names" 0 "$(grep -cE '[a-z]+/(boss|coordinator)' "$script" || true)"

# --- every way the factory hands work to a person ends in a label the bridge reads (#192) -------------

current="every handover in the factory scripts and workflows ends in a label the bridge reads"
src="$here/../.."
impl="$src/workflows/factory-implementer.yml"
has "implementer failure → record-failure" "record-failure.sh" "$(sed -n '/name: Record failure/,/^$/p' "$impl")"
has "record-failure → hand-to-human" 'hand-to-human.sh' "$(cat "$src/factory/record-failure.sh")"
for f in verify odin workflow-guard local-ticket; do
  has "$f → hand-to-human" 'hand-to-human.sh' "$(cat "$src/factory/$f.sh")"
done
has "hand-to-human adds ready-for-human" "LABEL=ready-for-human" "$(cat "$src/factory/hand-to-human.sh")"
has "local ticket reason" "<!-- factory-local -->" "$(cat "$src/factory/local-ticket.sh")"
has "spec budget → factory-paused" "factory-paused" "$(cat "$src/factory/ledger.sh")"
has "question → needs-decision" "needs-decision" "$(cat "$src/factory/decompose.md")"
has "check issue → human-check" "human-check" "$(cat "$src/factory/human-check.sh")"
for l in needs-decision human-check ready-for-human factory-paused; do
  has "bridge reads $l" "$l" "$(sed -n '/^for label in/p' "$script")"
done
for m in factory-budget-daily factory-queue-empty factory-idle factory-human-check; do
  has "bridge reads $m" "<!-- $m" "$(sed -n '/^matches=/,/@tsv/p' "$script")"
done

echo "bridge.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
