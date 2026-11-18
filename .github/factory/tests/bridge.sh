#!/usr/bin/env bash
# Tests of .github/factory/bridge.sh (marker comments → switchboard mailbox) against the fake gh and switchboard.
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
  unset BRIDGE_TO BRIDGE_TO_BOSS BRIDGE_TO_COORD BRIDGE_CC SWITCHBOARD_PROFILE
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

# issue <n> <state> <labels comma-separated> <title>
issue() {
  jq -n --argjson n "$1" --arg s "$2" --arg l "$3" --arg t "$4" \
    '{number: $n, state: $s, title: $t, html_url: "https://github.com/owner/repo/issues/\($n)",
      labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# comment <id> <issue> <body> [author login, default github-actions[bot]]
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
remembered() { tr '\n' ' ' < "$XDG_STATE_HOME/repo-factory-bridge/sent" | sed 's/ $//'; }

# A repository with one of each marker, plus noise.
markers() {
  issue 249 open spec,needs-decision "공장 개선"
  issue 250 open spec,factory-paused "검색"
  issue 900 open factory-ledger "장부"
  issue 301 open ready-for-human "티켓 하나"
  comment 11 249 "<!-- factory-question -->
무엇이 갈리는가: A냐 B냐. 권장안: A"
  comment 12 250 "<!-- factory-budget-spec -->
spec 상한: \$61 / \$60"
  comment 13 900 "<!-- factory-budget-daily 2026-11-17 -->
하루 상한"
  comment 14 301 "<!-- factory-human -->
되돌림 두 번"
  comment 15 249 "그냥 댓글"
}

# --- sending -------------------------------------------------------------------------------

setup "each marker is mailed once with its link, body and what to do"
markers
run
eq code 0 "$(code)"
eq sends 4 "$(sent_count)"
eq to "sandcorp/boss" "$(arg 0 --to)"
eq task repo-factory "$(arg 0 --task)"
eq key repo-factory-11 "$(arg 0 --idempotency-key)"
eq key4 repo-factory-14 "$(arg 3 --idempotency-key)"
eq profile automation "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"
has subject "질문: #249 공장 개선" "$(arg 0 --subject)"
body=$(arg 0 --body)
has "issue link" "https://github.com/owner/repo/issues/249" "$body"
has "comment link" "#issuecomment-11" "$body"
has "comment body" "A냐 B냐. 권장안: A" "$body"
has "question todo" "needs-decision 라벨을 떼면" "$body"
has "spec budget todo" "factory-paused" "$(arg 1 --body)"
has "daily todo" "KST 0시" "$(arg 2 --body)"
has "human reason" "되돌림 두 번" "$(arg 3 --body)"
has "human kind" "사람 넘김" "$(arg 3 --subject)"
eq remembered "11 12 13 14" "$(remembered)"

setup "a second run sends nothing again"
markers
run
run
eq code 0 "$(code)"
eq sends 4 "$(sent_count)"

setup "only the new marker is sent on the next run"
markers
run
comment 16 301 "<!-- factory-human -->
다시"
run
eq sends 5 "$(sent_count)"
eq key repo-factory-16 "$(arg 4 --idempotency-key)"

setup "a question goes to the boss and every other kind to the coordinator"
markers
issue 900 open factory-ledger "장부"
comment 21 900 "<!-- factory-queue-empty 245 -->"
comment 22 900 "<!-- factory-idle 245 -->"
run
eq code 0 "$(code)"
eq sends 6 "$(sent_count)"
eq "question to" sandcorp/boss "$(arg 0 --to)"
eq "budget-spec to" repo/coordinator "$(arg 1 --to)"
eq "budget-daily to" repo/coordinator "$(arg 2 --to)"
eq "human to" repo/coordinator "$(arg 3 --to)"
eq "queue-empty to" repo/coordinator "$(arg 4 --to)"
eq "idle to" repo/coordinator "$(arg 5 --to)"
has "log names the recipient" "sent human #301 to repo/coordinator" "$(cat "$tmp/log")"

setup "BRIDGE_TO_BOSS, BRIDGE_TO_COORD and SWITCHBOARD_PROFILE are passed through"
markers
export BRIDGE_TO_BOSS=boss/else BRIDGE_TO_COORD=coord/else SWITCHBOARD_PROFILE=other
run
eq "question to" boss/else "$(arg 0 --to)"
eq "human to" coord/else "$(arg 3 --to)"
eq profile other "$(jq -s -r '.[0].profile' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"

setup "a leftover BRIDGE_TO is ignored with a warning and never sends a question to the coordinator"
markers
export BRIDGE_TO=repo/coordinator
run
eq code 0 "$(code)"
eq "question to" sandcorp/boss "$(arg 0 --to)"
eq "human to" repo/coordinator "$(arg 3 --to)"
eq "budget-spec to" repo/coordinator "$(arg 1 --to)"
has warning "BRIDGE_TO is ignored" "$(cat "$tmp/log")"

setup "a human-check (#167) goes to the boss, once"
issue 950 open human-check "사람 확인: spec #62"
comment 31 950 "<!-- factory-human-check 62 -->
spec #62 의 티켓이 모두 병합됐다."
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"
eq "human-check to" sandcorp/boss "$(arg 0 --to)"
has subject "사람 확인 대기: #950" "$(arg 0 --subject)"
has todo "모두 체크하거나 이슈를 닫으면" "$(arg 0 --body)"
run
eq "not sent again" 1 "$(sent_count)"
setup "a human-check follows BRIDGE_TO_BOSS"
issue 950 open human-check "사람 확인: spec #62"
comment 31 950 "<!-- factory-human-check 62 -->"
export BRIDGE_TO_BOSS=boss/else BRIDGE_TO_COORD=coord/else
run
eq "human-check to" boss/else "$(arg 0 --to)"

# --- what is not sent ----------------------------------------------------------------------

setup "a question whose needs-decision is gone, and closed issues, are not sent"
issue 249 open spec "공장 개선"
issue 260 closed spec,needs-decision "닫힌 spec"
comment 11 249 "<!-- factory-question -->
A냐 B냐"
comment 12 260 "<!-- factory-question -->
닫힘"
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
eq remembered "" "$(remembered)"
issue 249 open spec,needs-decision "공장 개선"
run
eq "sent after the label is back" 1 "$(sent_count)"

# --- who wrote the marker ------------------------------------------------------------------

# perm <login> <permission> [role_name]
perm() {
  jq -n --arg p "$2" --arg r "${3:-$2}" '{permission: $p, role_name: $r}' | tr -d '\r' \
    > "$FAKE_GH/permission-$1.json"
}
perm_calls() { grep -c 'collaborators/.*/permission' "$FAKE_GH/calls.log" || true; }

setup "a marker by someone without write access is not sent and not looked at again"
issue 249 open spec,needs-decision "공장 개선"
issue 301 open ready-for-human "티켓 하나"
comment 11 249 "<!-- factory-question -->
가짜 질문" stranger
comment 12 301 "<!-- factory-human -->
가짜 넘김" stranger
perm stranger read
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
eq remembered "11 12" "$(remembered)"
has log "ignored question #249 by stranger" "$(cat "$tmp/log")"
eq "asked once per run" 1 "$(perm_calls)"
run
eq sends 0 "$(sent_count)"
eq "not asked again" 1 "$(perm_calls)"

setup "a triage collaborator is not trusted either"
issue 249 open spec,needs-decision "공장 개선"
comment 11 249 "<!-- factory-question -->
질문" helper
perm helper read triage
run
eq sends 0 "$(sent_count)"
eq remembered "11" "$(remembered)"

setup "markers by github-actions[bot] are sent without asking"
markers
run
eq sends 4 "$(sent_count)"
eq "no permission lookups" 0 "$(perm_calls)"

setup "a marker by the factory App is sent without asking (#172)"
issue 301 open ready-for-human "티켓 하나"
comment 11 301 "<!-- factory-human -->
넘김" "sandcorp-factory[bot]"
run
eq sends 1 "$(sent_count)"
eq "no permission lookups" 0 "$(perm_calls)"

setup "markers by write, maintain and admin collaborators are sent"
issue 249 open spec,needs-decision "공장 개선"
issue 301 open ready-for-human "티켓 하나"
issue 302 open ready-for-human "티켓 둘"
comment 11 249 "<!-- factory-question -->
질문" writer
comment 12 301 "<!-- factory-human -->
넘김" keeper
comment 13 302 "<!-- factory-human -->
넘김" boss
comment 14 302 "<!-- factory-human -->
또" writer
perm writer write
perm keeper write maintain
perm boss admin
run
eq code 0 "$(code)"
eq sends 4 "$(sent_count)"
eq remembered "11 12 13 14" "$(remembered)"
eq "one lookup per author" 3 "$(perm_calls)"

setup "a permission that cannot be read is retried next run"
issue 301 open ready-for-human "티켓 하나"
comment 12 301 "<!-- factory-human -->
넘김" writer
perm writer write
touch "$FAKE_GH/fail-permission"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
eq remembered "" "$(remembered)"
rm "$FAKE_GH/fail-permission"
run
eq code 0 "$(code)"
eq sends 1 "$(sent_count)"

setup "--seed also remembers markers by others"
issue 301 open ready-for-human "티켓 하나"
comment 12 301 "<!-- factory-human -->
가짜" stranger
run --seed
eq sends 0 "$(sent_count)"
eq remembered "12" "$(remembered)"

# --- failures ------------------------------------------------------------------------------

setup "a failed send is not remembered and is retried next time"
markers
touch "$FAKE_MAIL/fail"
run
eq code 1 "$(code)"
eq sends 0 "$(sent_count)"
eq remembered "" "$(remembered)"
rm "$FAKE_MAIL/fail"
run
eq code 0 "$(code)"
eq sends 4 "$(sent_count)"

# --- seed ----------------------------------------------------------------------------------

setup "--seed remembers the markers without sending"
markers
run --seed
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
eq calls 0 "$([ -f "$FAKE_MAIL/calls.log" ] && wc -l < "$FAKE_MAIL/calls.log" | tr -d ' ' || echo 0)"
eq remembered "11 12 13 14" "$(remembered)"
comment 16 301 "<!-- factory-human -->
다시"
run
eq "only the new one after seeding" 1 "$(sent_count)"
eq key repo-factory-16 "$(arg 0 --idempotency-key)"

# --- the script itself ---------------------------------------------------------------------

current="no address, token, host or home path in the script"
eq "http" 0 "$(grep -c 'https\?://' "$script" || true)"
eq "home" 0 "$(grep -ci '/home/\|/Users/\|C:\\' "$script" || true)"
eq "token" 0 "$(grep -ci 'token' "$script" || true)"

# --- spec queue markers on the ledger (#280) ------------------------------------------------

setup "queue-empty and idle are sent with their label and what to do"
issue 900 open factory-ledger "장부"
comment 21 900 "<!-- factory-queue-empty 245 -->
spec 큐 바닥남: #245"
comment 22 900 "<!-- factory-idle 245 -->
공장 idle"
run
eq code 0 "$(code)"
eq sends 2 "$(sent_count)"
has "queue-empty subject" "spec 큐 바닥남: #900 장부" "$(arg 0 --subject)"
has "queue-empty kind" "종류: spec 큐 바닥남" "$(arg 0 --body)"
has "queue-empty comment" "<!-- factory-queue-empty 245 -->" "$(arg 0 --body)"
has "queue-empty todo" "할 일: 다음 spec을 FACTORY_SPEC_QUEUE에 넣는다(조율자 몫)." "$(arg 0 --body)"
has "idle subject" "공장 idle: #900 장부" "$(arg 1 --subject)"
has "idle todo" "할 일: FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다(조율자 몫)." "$(arg 1 --body)"
eq key repo-factory-22 "$(arg 1 --idempotency-key)"
eq remembered "21 22" "$(remembered)"
run
eq "not again" 2 "$(sent_count)"

setup "queue markers by someone without write access are not sent"
issue 900 open factory-ledger "장부"
comment 23 900 "<!-- factory-idle none -->" mallory
comment 24 900 "<!-- factory-queue-empty 1 -->" mallory
run
eq code 0 "$(code)"
eq sends 0 "$(sent_count)"
eq remembered "23 24" "$(remembered)"

# --- BRIDGE_CC (#188) ----------------------------------------------------------------------

setup "without BRIDGE_CC only the coordinator gets its kinds (as before)"
markers
run
eq sends 4 "$(sent_count)"
eq "no cc key" 0 "$(grep -c -- '-cc-' "$FAKE_MAIL/calls.log")"

setup "the coordinator's kinds are also sent to every BRIDGE_CC recipient, each with its own key"
markers
issue 900 open factory-ledger "장부"
comment 21 900 "<!-- factory-queue-empty 245 -->"
comment 22 900 "<!-- factory-idle 245 -->"
comment 25 301 "<!-- factory-human-check 245 -->"
export BRIDGE_CC="cc/one  cc/two"
run
eq code 0 "$(code)"
# question 1 + human-check 1 (boss only) + 5 coordinator kinds x 3 recipients
eq sends 17 "$(sent_count)"
eq "question to" sandcorp/boss "$(arg 0 --to)"
eq "budget-spec to" repo/coordinator "$(arg 1 --to)"
eq "budget-spec key" repo-factory-12 "$(arg 1 --idempotency-key)"
eq "budget-spec cc to" cc/one "$(arg 2 --to)"
eq "budget-spec cc key" repo-factory-12-cc-cc-one "$(arg 2 --idempotency-key)"
eq "budget-spec cc2 to" cc/two "$(arg 3 --to)"
eq "budget-spec cc2 key" repo-factory-12-cc-cc-two "$(arg 3 --idempotency-key)"
eq "cc subject" "$(arg 1 --subject)" "$(arg 2 --subject)"
eq "cc body" "$(arg 1 --body)" "$(arg 2 --body)"
eq "human cc" cc/one "$(jq -s -r '[.[] | select(.args | index("repo-factory-14-cc-cc-one"))] | .[0].args as $a | $a[($a | index("--to")) + 1]' "$FAKE_MAIL/sent.jsonl" | tr -d '\r')"
eq "human-check not copied" 1 "$(grep -c -- 'repo-factory-25' "$FAKE_MAIL/calls.log")"
eq remembered "11 12 13 14 21 22 25" "$(remembered)"
run
eq "second run sends nothing" 17 "$(sent_count)"

setup "the coordinator listed in BRIDGE_CC, or a recipient listed twice, gets one mail"
issue 301 open ready-for-human "티켓 하나"
comment 14 301 "<!-- factory-human -->"
export BRIDGE_CC="repo/coordinator cc/one cc/one"
run
eq sends 2 "$(sent_count)"
eq to repo/coordinator "$(arg 0 --to)"
eq "cc to" cc/one "$(arg 1 --to)"

setup "markers sent before BRIDGE_CC was set are not sent to the new recipients"
markers
run
eq sends 4 "$(sent_count)"
export BRIDGE_CC=cc/one
run
eq "no old markers" 4 "$(sent_count)"
comment 16 301 "<!-- factory-human -->
다시"
run
eq "the new marker to both" 6 "$(sent_count)"
eq to repo/coordinator "$(arg 4 --to)"
eq key repo-factory-16 "$(arg 4 --idempotency-key)"
eq "cc to" cc/one "$(arg 5 --to)"

setup "a failed CC send is retried alone; the coordinator is not mailed twice"
issue 301 open ready-for-human "티켓 하나"
comment 14 301 "<!-- factory-human -->"
export BRIDGE_CC="cc/one cc/two"
echo cc/two > "$FAKE_MAIL/fail-to"
run
eq code 1 "$(code)"
eq sends 2 "$(sent_count)"
eq remembered "14 repo/coordinator 14 cc/one" "$(remembered)"
has "log names the failed recipient" "to cc/two (comment 14); will retry" "$(cat "$tmp/log")"
rm "$FAKE_MAIL/fail-to"
run
eq code 0 "$(code)"
eq sends 3 "$(sent_count)"
eq "retry to" cc/two "$(arg 2 --to)"
eq "retry key" repo-factory-14-cc-cc-two "$(arg 2 --idempotency-key)"
run
eq "nothing more" 3 "$(sent_count)"

setup "--seed with BRIDGE_CC sends nothing to anyone"
markers
export BRIDGE_CC=cc/one
run --seed
eq sends 0 "$(sent_count)"
run
eq sends 0 "$(sent_count)"

# --- every way the factory hands work to a person leaves a marker the bridge reads (#188) ----

setup "a local ticket (local-ticket.sh) is sent to the coordinator and CC"
issue 302 open ready-for-human,local "워크플로 티켓"
comment 31 302 "<!-- factory-local -->
workflow·\`.claude/\` 파일 — 로컬 작업자 몫."
export BRIDGE_CC=cc/one
run
eq sends 2 "$(sent_count)"
eq to repo/coordinator "$(arg 0 --to)"
has subject "로컬 작업자 몫: #302" "$(arg 0 --subject)"
eq "cc to" cc/one "$(arg 1 --to)"

setup "every handover in the factory scripts and workflows carries a marker the bridge reads"
# Each place that adds ready-for-human / needs-decision / factory-paused, or stops for a person,
# must write one of these markers in the same step (grep of the sources, not a run).
src="$here/../.."
impl="$src/workflows/factory-implementer.yml"
has "implementer fail limit" '<!-- factory-human -->
          Implementer failed' "$(sed -n '/Record failure/,/ready-for-agent/p' "$impl")"
has "verify limit" "HUMAN='<!-- factory-human -->'" "$(cat "$src/factory/verify.sh")"
has "odin human marker" "HUMAN='<!-- factory-human -->'" "$(cat "$src/factory/odin.sh")"
has "odin human uses it" 'comment "$s" "$HUMAN' "$(sed -n '/^human()/,/^}/p' "$src/factory/odin.sh")"
has "workflow guard" "factory-human" "$(cat "$src/factory/workflow-guard.sh")"
has "local ticket" "<!-- factory-local -->" "$(cat "$src/factory/local-ticket.sh")"
has "spec budget" "factory-budget-spec" "$(cat "$src/factory/ledger.sh")"
has "daily budget" "factory-budget-daily" "$(cat "$src/factory/ledger.sh")"
has "human check" "factory-human-check" "$(cat "$src/factory/human-check.sh")"
for m in factory-human factory-local factory-question factory-budget-spec factory-budget-daily \
  factory-queue-empty factory-idle factory-human-check; do
  has "bridge reads $m" "<!-- $m" "$(sed -n '/^matches=/,/@tsv/p' "$script")"
done

echo "bridge.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
