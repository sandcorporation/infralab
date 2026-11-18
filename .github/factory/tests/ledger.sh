#!/usr/bin/env bash
# Tests of .github/factory/ledger.sh against the fake gh (tests/fake/gh).
set -u
here=$(cd "$(dirname "$0")" && pwd)
ledger="$here/../ledger.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# --- helpers -------------------------------------------------------------------------------

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" RUNNER_TEMP="$tmp/runner" GITHUB_OUTPUT="$tmp/output"
  mkdir -p "$FAKE_GH" "$RUNNER_TEMP"
  : > "$GITHUB_OUTPUT"
  export GITHUB_RUN_ID=777 FACTORY_NOW=1794884400 # 2026-11-17T03:00:00Z = 12:00 KST
  unset FACTORY_SPEC_BUDGET_USD FACTORY_DAILY_BUDGET_USD FAKE_GH_NOW
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}

# issue <n> <labels comma-separated> <body>
issue() {
  jq -n --argjson n "$1" --arg l "$2" --arg b "$3" \
    '{number: $n, state: "open", body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# ledger_comment <created_at> <spec> <cost>: a ledger comment on the ledger issue #900
ledger_comment() {
  local f="$FAKE_GH/comments-900.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg t "$1" --arg b "<!-- ledger -->
spec=#$2 node=implementer issue=#$2 run=1 cost=$3 turns=1 input=1 output=1 cache_read=0 cache_write=0" \
    '. + [{id: (length + 1), created_at: $t, body: $b}]' "$f" | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

with_ledger() { issue 900 factory-ledger "장부"; }

comment_count() { # comment_count <n> <first line>
  local f="$FAKE_GH/comments-$1.json"
  [ -f "$f" ] || { echo 0; return; }
  jq --arg m "$2" '[.[] | select(.body | startswith($m))] | length' "$f" | tr -d '\r'
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }

labels_of() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }

execution_file() {
  cat > "$RUNNER_TEMP/claude-execution-output.json" <<'EOF'
[
  {"type": "system", "subtype": "init"},
  {"type": "assistant", "message": {"content": []}},
  {"type": "result", "subtype": "success", "total_cost_usd": 0.5,
   "num_turns": 3, "usage": {"input_tokens": 10, "output_tokens": 20}},
  {"type": "result", "subtype": "success", "total_cost_usd": 1.2345,
   "num_turns": 42, "usage": {"input_tokens": 1000, "output_tokens": 2000,
   "cache_read_input_tokens": 30000, "cache_creation_input_tokens": 4000}}
]
EOF
}

# --- record --------------------------------------------------------------------------------

setup "record: a ticket's run becomes one ledger line under its spec"
with_ledger
issue 249 spec "spec body"
issue 300 "" "## Parent

#249

## What to build

Mentions #12 elsewhere."
execution_file
bash "$ledger" record implementer 300 > /dev/null
eq "exit" 0 $?
body=$(jq -r '.[-1].body' "$FAKE_GH/comments-900.json" | tr -d '\r')
eq "comment" "<!-- ledger -->
spec=#249 node=implementer issue=#300 run=777 cost=1.2345 turns=42 input=1000 output=2000 cache_read=30000 cache_write=4000" "$body"
eq "execution file moved away" "" "$(ls "$RUNNER_TEMP"/claude-execution-output.json 2>/dev/null)"
eq "kept under factory-runs" 1 "$(ls "$RUNNER_TEMP"/factory-runs | wc -l | tr -d ' ')"
# A later stage that was skipped must not count the same run again.
bash "$ledger" record implementer-fix 300 > /dev/null
eq "second record without a file" 0 $?
eq "still one ledger comment" 1 "$(comment_count 900 '<!-- ledger -->')"

setup "record: a spec's own run is under the spec"
with_ledger
issue 249 spec "no parent here"
execution_file
bash "$ledger" record decompose 249 > /dev/null
line=$(jq -r '.[-1].body' "$FAKE_GH/comments-900.json" | tr -d '\r' | sed -n 2p)
eq "spec of a spec" "spec=#249 node=decompose issue=#249" "${line%% run=*}"

setup "record: no result in the execution file still leaves a zero line"
with_ledger
issue 5 "" "x"
echo '[{"type": "system"}]' > "$RUNNER_TEMP/claude-execution-output.json"
bash "$ledger" record decompose 5 > /dev/null
line=$(jq -r '.[-1].body' "$FAKE_GH/comments-900.json" | tr -d '\r' | sed -n 2p)
eq "zero line" "spec=#5 node=decompose issue=#5 run=777 cost=0 turns=0 input=0 output=0 cache_read=0 cache_write=0 note=no-result" "$line"

setup "record: never fails the workflow"
issue 5 "" "x"
bash "$ledger" record decompose 5 > /dev/null
eq "no execution file" 0 $?
execution_file
bash "$ledger" record decompose 5 > "$tmp/log" 2>&1
eq "no ledger issue" 0 $?
grep -q '::warning::' "$tmp/log" && ok || bad "no warning without a ledger issue"
with_ledger
touch "$FAKE_GH/fail-comments"
execution_file
bash "$ledger" record decompose 5 > /dev/null 2>&1
eq "commenting fails" 0 $?

setup "record: no ledger issue is created and the cost recorded on it"
issue 5 "" "x"
execution_file
bash "$ledger" record decompose 5 > /dev/null
n=$(grep -l factory-ledger "$FAKE_GH"/issue-*.json | sed 's/.*issue-\([0-9]*\).json/\1/')
eq "one ledger issue made" 1 "$(printf '%s\n' "$n" | grep -c .)"
eq "its title" "공장 비용 장부" "$(jq -r .title "$FAKE_GH/issue-$n.json")"
eq "the cost is on it" 1 "$(comment_count "$n" '<!-- ledger -->')"
execution_file
bash "$ledger" record decompose 5 > /dev/null
eq "the second record reuses it" 2 "$(comment_count "$n" '<!-- ledger -->')"
eq "still one ledger issue" 1 "$(grep -l factory-ledger "$FAKE_GH"/issue-*.json | grep -c .)"

setup "spec-of: the GitHub sub-issue parent first, then the Parent section"
issue 7 "" "no section"
echo '{"number": 40}' > "$FAKE_GH/parent-7.json"
eq "sub-issue parent" 40 "$(bash "$ledger" spec-of 7)"
issue 8 "" "## Parent

#41"
eq "Parent section" 41 "$(bash "$ledger" spec-of 8)"
echo '{"number": 42}' > "$FAKE_GH/parent-8.json"
eq "the sub-issue parent wins" 42 "$(bash "$ledger" spec-of 8)"
issue 9 "" "x"
eq "none: the issue itself" 9 "$(bash "$ledger" spec-of 9)"
eq "parent-of none: empty" "" "$(bash "$ledger" parent-of 9)"

# --- totals --------------------------------------------------------------------------------

setup "spec-total adds the spec's lines only"
with_ledger
ledger_comment 2026-11-17T01:00:00Z 1 1.5
ledger_comment 2026-11-17T02:00:00Z 2 10
ledger_comment 2026-11-17T03:00:00Z 1 2.25
eq "spec 1" 3.7500 "$(bash "$ledger" spec-total 1)"
eq "spec 2" 10.0000 "$(bash "$ledger" spec-total 2)"
eq "spec 3" 0.0000 "$(bash "$ledger" spec-total 3)"

setup "day-total groups by KST date (UTC 15:00 is KST midnight)"
with_ledger
ledger_comment 2026-11-16T15:00:00Z 1 4      # 11-17 00:00 KST
ledger_comment 2026-11-17T14:59:00Z 1 1      # 11-17 23:59 KST
ledger_comment 2026-11-17T15:00:00Z 2 2      # 11-18 00:00 KST
ledger_comment 2026-11-16T14:59:59Z 2 8      # 11-16 23:59 KST
eq "11-17" 5.0000 "$(bash "$ledger" day-total 2026-11-17)"
eq "11-18" 2.0000 "$(bash "$ledger" day-total 2026-11-18)"
eq "11-16" 8.0000 "$(bash "$ledger" day-total 2026-11-16)"
eq "today (FACTORY_NOW = 11-17 KST)" 5.0000 "$(bash "$ledger" day-total)"
FACTORY_NOW=1794927600 # 2026-11-17T15:00:00Z
eq "today after UTC 15:00" 2.0000 "$(bash "$ledger" day-total)"

setup "no ledger issue: totals are zero"
eq "spec" 0.0000 "$(bash "$ledger" spec-total 1)"
eq "day" 0.0000 "$(bash "$ledger" day-total)"

# --- guard ---------------------------------------------------------------------------------

setup "guard: a fresh spec may start"
with_ledger
issue 249 spec "spec"
issue 300 ready-for-agent "## Parent
#249"
bash "$ledger" guard 300 > /dev/null
eq "go" true "$(out go)"

for label in needs-decision factory-paused; do
  setup "guard: $label on the spec stops its tickets"
  with_ledger
  issue 249 "spec,$label" "spec"
  issue 300 "" "## Parent
#249"
  bash "$ledger" guard 300 > /dev/null
  eq "go" false "$(out go)"
  eq "reason" "$label" "$(out reason)"
  eq "no comment on the spec" 0 "$(comment_count 249 '<!--')"
done

setup "guard: spec budget defaults to 60"
with_ledger
issue 249 spec "spec"
ledger_comment 2026-11-10T00:00:00Z 249 59.99
bash "$ledger" guard 249 > /dev/null
eq "under 60" true "$(out go)"
ledger_comment 2026-11-10T00:00:00Z 249 0.01
bash "$ledger" guard 249 > /dev/null
eq "at 60" false "$(out go)"
eq "reason" spec-budget "$(out reason)"
eq "labelled" "spec,factory-paused" "$(labels_of 249)"

setup "guard: FACTORY_SPEC_BUDGET_USD beats the default"
with_ledger
issue 249 spec "spec"
ledger_comment 2026-11-10T00:00:00Z 249 70
FACTORY_SPEC_BUDGET_USD=100 bash "$ledger" guard 249 > /dev/null
eq "70 of 100" true "$(out go)"
FACTORY_SPEC_BUDGET_USD=50 bash "$ledger" guard 249 > /dev/null
eq "70 of 50" false "$(out go)"

setup "guard: the body's 예산 line beats the variable"
with_ledger
issue 249 spec "## Problem

예산: \$80

text"
ledger_comment 2026-11-10T00:00:00Z 249 70
FACTORY_SPEC_BUDGET_USD=50 bash "$ledger" guard 249 > /dev/null
eq "70 of body 80 (variable 50)" true "$(out go)"
issue 249 spec "예산: \$5.5"
FACTORY_SPEC_BUDGET_USD=100 bash "$ledger" guard 249 > /dev/null
eq "70 of body 5.5 (variable 100)" false "$(out go)"
issue 249 spec "예산: 90"
bash "$ledger" guard 249 > /dev/null
eq "without the dollar sign" true "$(out go)"

setup "guard: a ticket counts against its parent spec"
with_ledger
issue 249 spec "spec"
issue 300 "" "## Parent

#249"
ledger_comment 2026-11-10T00:00:00Z 249 61
bash "$ledger" guard 300 > /dev/null
eq "go" false "$(out go)"
eq "paused the spec" "spec,factory-paused" "$(labels_of 249)"
eq "ticket untouched" "" "$(labels_of 300)"

setup "guard: the spec marker is left once"
with_ledger
issue 249 spec "spec"
ledger_comment 2026-11-10T00:00:00Z 249 61
bash "$ledger" guard 249 > /dev/null
issue 249 spec "spec"   # someone took factory-paused off without raising the budget
bash "$ledger" guard 249 > /dev/null
eq "one marker" 1 "$(comment_count 249 '<!-- factory-budget-spec -->')"
eq "go" false "$(out go)"
issue 249 spec "예산: \$70"   # raised, spent again
ledger_comment 2026-11-10T00:00:00Z 249 10
bash "$ledger" guard 249 > /dev/null
eq "a new budget gets a new marker" 2 "$(comment_count 249 '<!-- factory-budget-spec -->')"

setup "guard: daily budget defaults to 150 per KST day"
with_ledger
issue 1 spec "예산: \$1000"
issue 2 spec "예산: \$1000"
ledger_comment 2026-11-16T15:00:00Z 1 100   # 11-17 KST
ledger_comment 2026-11-16T14:59:00Z 2 100   # 11-16 KST: does not count today
ledger_comment 2026-11-17T02:00:00Z 2 49.99 # 11-17 KST
bash "$ledger" guard 1 > /dev/null
eq "149.99" true "$(out go)"
ledger_comment 2026-11-17T02:30:00Z 2 0.01
bash "$ledger" guard 1 > /dev/null
eq "150" false "$(out go)"
eq "reason" daily "$(out reason)"
bash "$ledger" guard 2 > /dev/null
eq "every spec stops" false "$(out go)"
eq "one daily marker" 1 "$(comment_count 900 '<!-- factory-budget-daily 2026-11-17 -->')"
eq "no spec pause" "spec" "$(labels_of 1)"
FACTORY_NOW=1794927600 bash "$ledger" guard 1 > /dev/null # 11-18 00:00 KST
eq "next KST day" true "$(out go)"

setup "guard: FACTORY_DAILY_BUDGET_USD"
with_ledger
issue 1 spec "spec"
ledger_comment 2026-11-17T02:00:00Z 1 10
FACTORY_DAILY_BUDGET_USD=10 bash "$ledger" guard 1 > /dev/null
eq "10 of 10" false "$(out go)"
FACTORY_DAILY_BUDGET_USD=20 bash "$ledger" guard 1 > /dev/null
eq "10 of 20" true "$(out go)"

setup "guard: no ledger issue means nothing spent"
issue 1 spec "spec"
FACTORY_DAILY_BUDGET_USD=1 FACTORY_SPEC_BUDGET_USD=1 bash "$ledger" guard 1 > /dev/null
eq "go without a ledger" true "$(out go)"

setup "guard: an unreadable spec does not start"
issue 300 "" "## Parent
#999"
bash "$ledger" guard 300 > /dev/null
eq "go" false "$(out go)"
eq "reason" error "$(out reason)"

# --- event and stats (#286) ----------------------------------------------------------------

events() { # the event lines on the ledger
  jq -r '.[] | select(.body | startswith("<!-- factory-event -->")) | .body | split("\n")[1]' \
    "$FAKE_GH/comments-900.json" | tr -d '\r'
}

setup "event: impl-start waits since the last ready-for-agent label"
with_ledger; issue 7 ready-for-agent ""
jq -n '[{event: "labeled", created_at: "2026-11-17T01:00:00Z", label: {name: "ready-for-agent"}},
        {event: "labeled", created_at: "2026-11-17T02:50:00Z", label: {name: "ready-for-agent"}},
        {event: "labeled", created_at: "2026-11-17T02:55:00Z", label: {name: "model:sonnet"}}]' \
  | tr -d '\r' > "$FAKE_GH/events-7.json"
bash "$ledger" event impl-start 7 track=2 > /dev/null
eq "exit" 0 "$?"
eq "line" "event=impl-start issue=#7 track=2 wait=600 run=777" "$(events)"
eq "not a cost" 0 "$(comment_count 900 '<!-- ledger -->')"

setup "event: verify-start waits since the ticket's last impl-end"
with_ledger
FAKE_GH_NOW=2026-11-17T02:40:00Z bash "$ledger" event impl-end 7 track=1 > /dev/null
FAKE_GH_NOW=2026-11-17T02:45:00Z bash "$ledger" event impl-end 17 track=2 > /dev/null
bash "$ledger" event verify-start 7 pr=#40 > /dev/null
eq "wait from #7's hand-over, not #17's" "event=verify-start issue=#7 pr=#40 wait=1200 run=777" "$(events | tail -n 1)"

setup "event: no ledger, no wait, failures do not fail"
bash "$ledger" event impl-end 7 track=1 > /dev/null 2>&1
eq "no ledger: exit 0" 0 "$?"
with_ledger
bash "$ledger" event impl-start 7 > /dev/null 2>&1
eq "no label event: no wait" "event=impl-start issue=#7 run=777" "$(events)"
touch "$FAKE_GH/fail-comments"
bash "$ledger" event impl-end 7 > /dev/null 2>&1
eq "a failed comment: exit 0" 0 "$?"
REPO= GITHUB_REPOSITORY= bash "$ledger" event impl-end 7 > /dev/null 2>&1
eq "no REPO: exit 0" 0 "$?"

setup "stats: conflict send-back ratio and waits"
with_ledger
for l in "impl-start issue=#1 track=1 wait=100" "impl-start issue=#2 track=2 wait=300" \
         "impl-start issue=#3 track=1 wait=200" "verify-start issue=#1 pr=#40 wait=10" \
         "verify-start issue=#2 pr=#41 wait=50" "verify-end issue=#1 pr=#40 outcome=merged" \
         "verify-end issue=#2 pr=#41 outcome=conflict files=AGENTS.md,web/src/api.ts" \
         "verify-end issue=#3 pr=#42 outcome=rebase-ci" \
         "verify-end issue=#5 pr=#44 outcome=conflict files=agent/main.go,AGENTS.md" \
         "verify-end issue=#4 pr=#43 outcome=review"; do
  jq --arg b "<!-- factory-event -->
event=$l run=1" '. + [{id: (length + 1), created_at: "2026-11-17T01:00:00Z", body: $b}]' \
    "$FAKE_GH/comments-900.json" 2>/dev/null | tr -d '\r' > "$FAKE_GH/c.new" || true
  [ -s "$FAKE_GH/c.new" ] || jq -n --arg b "<!-- factory-event -->
event=$l run=1" '[{id: 1, created_at: "2026-11-17T01:00:00Z", body: $b}]' | tr -d '\r' > "$FAKE_GH/c.new"
  mv "$FAKE_GH/c.new" "$FAKE_GH/comments-900.json"
done
ledger_comment 2026-11-17T01:00:00Z 1 5
stats=$(bash "$ledger" stats | tr -d '\r')
eq "stats" "verify: 5 runs, conflict send-backs 3 (ratio 60%)
implementer wait, track 1: n=2 mean=150s max=200s
implementer wait, track 2: n=1 mean=300s max=300s
verify wait: n=2 mean=30s max=50s
conflicts per file:
  2 AGENTS.md
  1 agent/main.go
  1 web/src/api.ts" "$stats"
eq "sums untouched" 5.0000 "$(bash "$ledger" spec-total 1 | tr -d '\r')"

setup "stats: no conflicting files"
with_ledger
jq -n '[{id: 1, created_at: "2026-11-17T01:00:00Z",
  body: "<!-- factory-event -->\nevent=verify-end issue=#1 pr=#40 outcome=merged run=1"}]' \
  | tr -d '\r' > "$FAKE_GH/comments-900.json"
eq "none" "conflicts per file: none" "$(bash "$ledger" stats | tr -d '\r' | tail -n 1)"

echo "ledger: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
