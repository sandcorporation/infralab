#!/usr/bin/env bash
# Tests of .github/factory/dispatch-next.sh: --candidates and the second look at an empty label search
# (#267), the spec queue and its bridge markers (#280). Which ticket goes first after Odin is pinned in
# odin.sh's tests.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../dispatch-next.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}
lacks() { # lacks <what> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: [$2] unexpectedly in [$3]" ;; *) ok ;; esac
}

# issue <n> <labels csv> [blocked_by]: a ticket of spec #50
issue() {
  jq -n --argjson n "$1" --arg l "$2" --argjson b "${3:-0}" \
    '{number: $n, state: "open", body: "## Parent\n\n#50\n",
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      issue_dependencies_summary: {blocked_by: $b}}' | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FACTORY_LIST_RETRY_WAIT=0 FACTORY_TRACKS=1 FACTORY_DISPATCH_SEEN_WAIT=0
  unset FACTORY_SPEC_QUEUE
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}]}' | tr -d '\r' \
    > "$FAKE_GH/issue-50.json"
}

run() { bash "$script" "$@" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }
code() { cat "$tmp/code"; }
log() { cat "$tmp/log"; }
dispatched() { grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }
searches() { grep -c '^issue list .*--label ready-for-agent --limit' "$FAKE_GH/calls.log" || true; }

# --- candidates ----------------------------------------------------------------------------

setup "a candidate starts although the label search is empty"
issue 61 ready-for-agent 1
issue 62 ready-for-agent
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "61 62"
eq code 0 "$(code)"
eq "the unblocked candidate" 62 "$(dispatched)"
eq "no second search with candidates" 1 "$(searches)"

setup "candidates and the search together: the lowest number goes first"
issue 62 ready-for-agent
issue 65 ready-for-agent
run --candidates "65" --tickets-only
eq "lowest of both" 62 "$(dispatched)"

setup "a candidate without ready-for-agent or closed does not start"
issue 61 model:sonnet
issue 62 ready-for-agent
jq '.state = "closed"' "$FAKE_GH/issue-62.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-62.json"
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "61 62"
eq code 0 "$(code)"
eq "nothing dispatched" "" "$(dispatched)"
has "says so" "no unblocked approved ticket may start" "$(log)"

setup "a candidate of a paused spec does not start"
jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}, {name: "factory-paused"}]}' \
  | tr -d '\r' > "$FAKE_GH/issue-50.json"
issue 62 ready-for-agent
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "62"
eq "guard still applies" "" "$(dispatched)"

# --- an empty search without candidates ----------------------------------------------------

setup "an empty search is asked once more"
issue 62 ready-for-agent
touch "$FAKE_GH/list-empty-once"
run --tickets-only
eq code 0 "$(code)"
eq "found on the second search" 62 "$(dispatched)"
eq "two searches" 2 "$(searches)"
has "notice" "asking again in 0s" "$(log)"

setup "a search that finds tickets is not repeated"
issue 62 ready-for-agent
run --tickets-only
eq "dispatched" 62 "$(dispatched)"
eq "one search" 1 "$(searches)"

setup "still empty after the second search: nothing starts"
touch "$FAKE_GH/list-empty"
run --tickets-only
eq code 0 "$(code)"
eq "nothing dispatched" "" "$(dispatched)"
eq "two searches" 2 "$(searches)"

# --- arguments -----------------------------------------------------------------------------

setup "bad arguments"
run --candidates
eq "missing value" 2 "$(code)"
run --candidates "61 x"
eq "not a number" 2 "$(code)"
run --other
eq "unknown option" 2 "$(code)"
lacks "nothing dispatched" "workflow run" "$(cat "$FAKE_GH/calls.log")"

# --- the spec queue and the bridge markers (#280) ------------------------------------------

# spec <n> <labels csv> [state]: a spec of the queue with two tickets, one merged
spec() {
  jq -n --argjson n "$1" --arg l "$2" --arg s "${3:-open}" \
    '{number: $n, state: $s, body: "",
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      sub_issues_summary: {total: 2, completed: 1}}' | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}
ledger() {
  jq -n '{number: 900, state: "open", body: "", labels: [{name: "factory-ledger"}]}' | tr -d '\r' \
    > "$FAKE_GH/issue-900.json"
}
# marked <prefix>: the ledger comments starting with that text
marked() {
  [ -f "$FAKE_GH/comments-900.json" ] || { echo; return; }
  jq -r '.[].body | split("\n")[0]' "$FAKE_GH/comments-900.json" | tr -d '\r' | grep -F -- "$1" | tr '\n' ' ' \
    | sed 's/ $//'
}
decomposed() { grep '^workflow run factory-decompose.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }

setup "a spec that is not the last of the queue starts without a marker"
spec 50 spec; ledger; spec 60 ""; spec 61 ""
FACTORY_SPEC_QUEUE="60 61" run
eq code 0 "$(code)"
eq "decompose" 60 "$(decomposed)"
eq "labelled" true "$(jq 'any(.labels[]; .name == "spec")' "$FAKE_GH/issue-60.json" | tr -d '\r')"
eq "no marker" "" "$(marked '<!-- factory-')"

setup "the last spec of the queue starts: queue-empty once"
spec 50 spec; ledger; spec 60 spec; spec 61 ""; spec 62 "" closed
FACTORY_SPEC_QUEUE="60 61 62" run
eq code 0 "$(code)"
eq "decompose" 61 "$(decomposed)"
eq "queue-empty" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-')"
has "what to do" "FACTORY_SPEC_QUEUE" "$(jq -r '.[0].body' "$FAKE_GH/comments-900.json")"
# idle on the next call, once, then a new queue is told again
FACTORY_SPEC_QUEUE="60 61 62" run
eq code 0 "$(code)"
has "notice" "the factory is idle" "$(log)"
eq "idle" "<!-- factory-idle 60-61-62 -->" "$(marked '<!-- factory-idle')"
eq "one decompose" 61 "$(decomposed)"
FACTORY_SPEC_QUEUE="60 61 62" run
eq "not again" "<!-- factory-idle 60-61-62 -->" "$(marked '<!-- factory-idle')"
FACTORY_SPEC_QUEUE=" 60  61 " run
eq "a new queue" "<!-- factory-idle 60-61-62 --> <!-- factory-idle 60-61 -->" "$(marked '<!-- factory-idle')"
eq "queue-empty not again" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-queue-empty')"

setup "an empty queue is idle as none"
spec 50 spec; ledger
run
eq code 0 "$(code)"
eq "idle none" "<!-- factory-idle none -->" "$(marked '<!-- factory-')"

setup "a queue-empty marker already there is not left again"
spec 50 spec; ledger; spec 61 ""
jq -n '[{id: 1, created_at: "2026-11-17T01:00:00Z", body: "<!-- factory-queue-empty 61 -->\n앞서 남김"}]' \
  | tr -d '\r' > "$FAKE_GH/comments-900.json"
FACTORY_SPEC_QUEUE="61" run
eq "decompose" 61 "$(decomposed)"
eq "one marker" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-')"

setup "a failed comment does not change the exit code"
spec 50 spec; ledger; spec 61 ""
touch "$FAKE_GH/fail-comments"
FACTORY_SPEC_QUEUE="61" run
eq code 0 "$(code)"
eq "decompose" 61 "$(decomposed)"
has "warns" "could not leave <!-- factory-queue-empty 61 -->" "$(log)"
FACTORY_SPEC_QUEUE="61" run
eq "idle code" 0 "$(code)"
has "idle notice" "the factory is idle" "$(log)"
has "warns" "could not leave <!-- factory-idle 61 -->" "$(log)"
eq "no marker" "" "$(marked '<!-- factory-')"

# --- unchecked 사람 확인 items hold the spec open (#167) ---------------------------------------

# done_spec: spec #50 with every ticket merged; check <state> <body>: its check issue #850
done_spec() {
  jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}],
    sub_issues_summary: {total: 2, completed: 2}}' | tr -d '\r' > "$FAKE_GH/issue-50.json"
}
check() {
  jq -n --arg s "$1" --arg b "<!-- factory-human-check-of 50 -->
spec: #50

$2" '{number: 850, state: $s, title: "사람 확인: spec #50", body: $b, labels: [{name: "human-check"}]}' \
    | tr -d '\r' > "$FAKE_GH/issue-850.json"
}
spec_state() { jq -r .state "$FAKE_GH/issue-50.json" | tr -d '\r'; }
hc_marks() {
  [ -f "$FAKE_GH/comments-850.json" ] || { echo 0; return; }
  jq '[.[] | select(.body | startswith("<!-- factory-human-check 50 -->"))] | length' "$FAKE_GH/comments-850.json" | tr -d '\r'
}

setup "an unchecked item keeps the spec open, holds the next spec and is told once"
done_spec; ledger; spec 60 ""
check open "- [x] 붙여넣기 신호 (PR #40)
- [ ] 환경 준비 표시 (PR #41)"
FACTORY_SPEC_QUEUE="60" run
eq code 0 "$(code)"
eq "spec stays open" open "$(spec_state)"
eq "next spec not started" "" "$(decomposed)"
has notice "spec #50 waits for its 사람 확인 items" "$(log)"
eq "marker on the check issue" 1 "$(hc_marks)"
has "the count is told" "사람 확인 1 건이 미체크" "$(jq -r '.[0].body' "$FAKE_GH/comments-850.json")"
FACTORY_SPEC_QUEUE="60" run
eq "still open" open "$(spec_state)"
eq "marker not again" 1 "$(hc_marks)"
eq "still no next spec" "" "$(decomposed)"

setup "items stacked after the marker are told again, once; no new item, no new marker (#170)"
done_spec; ledger; spec 60 ""
check open "- [x] 붙여넣기 신호 (PR #40)
- [ ] 환경 준비 표시 (PR #41)"
FACTORY_SPEC_QUEUE="60" run
eq "first marker" 1 "$(hc_marks)"
check open "- [x] 붙여넣기 신호 (PR #40)
- [ ] 환경 준비 표시 (PR #41)
- [ ] 종료 화면 (PR #43)"
FACTORY_SPEC_QUEUE="60" run
eq "second marker for the new item" 2 "$(hc_marks)"
has "new item told" "종료 화면 (PR #43)" "$(jq -r '.[1].body' "$FAKE_GH/comments-850.json")"
eq "old item not told again" 0 "$(jq -r '.[1].body' "$FAKE_GH/comments-850.json" | grep -c '환경 준비 표시')"
FACTORY_SPEC_QUEUE="60" run
eq "no third marker" 2 "$(hc_marks)"
check open "- [x] 붙여넣기 신호 (PR #40)
- [x] 환경 준비 표시 (PR #41)
- [ ] 종료 화면 (PR #43)"
FACTORY_SPEC_QUEUE="60" run
eq "an item checked is not new" 2 "$(hc_marks)"

setup "every item checked: the spec closes and the next one starts"
done_spec; ledger; spec 60 ""
check open "- [x] 붙여넣기 신호 (PR #40)
- [X] 환경 준비 표시 (PR #41)"
FACTORY_SPEC_QUEUE="60" run
eq code 0 "$(code)"
eq "spec closed" closed "$(spec_state)"
eq "next spec" 60 "$(decomposed)"
eq "no marker" 0 "$(hc_marks)"

setup "a closed check issue lets the spec close"
done_spec; ledger
check closed "- [ ] 환경 준비 표시 (PR #41)"
run
eq "spec closed" closed "$(spec_state)"

setup "a spec without a check issue closes as before"
done_spec; ledger
run
eq "spec closed" closed "$(spec_state)"

# spec_mark <body>: a marker comment of human-check.sh stack on spec #50 (#183)
spec_mark() {
  [ -f "$FAKE_GH/comments-50.json" ] || echo '[]' > "$FAKE_GH/comments-50.json"
  jq --arg b "$1" '. + [{id: (length + 1), created_at: "2026-11-17T02:00:00Z", body: $b, user: {login: "github-actions[bot]"}}]' \
    "$FAKE_GH/comments-50.json" | tr -d '\r' > "$FAKE_GH/c.new" && mv "$FAKE_GH/c.new" "$FAKE_GH/comments-50.json"
}

setup "a check issue missing from the label list is found by the spec's marker and holds the spec (#183)"
done_spec; ledger
check open "- [ ] Closes #179 (PR #181)"
spec_mark "<!-- factory-human-check-issue -->"
spec_mark "<!-- factory-human-check-issue 850 -->"
touch "$FAKE_GH/labels-lag"
run
eq "spec stays open" open "$(spec_state)"
has notice "spec #50 waits for its 사람 확인 items" "$(log)"
eq "marker on the check issue" 1 "$(hc_marks)"

setup "a stack began but its check issue is not found: the spec stays open (#183)"
done_spec; ledger
check open "- [ ] 환경 준비 표시 (PR #41)"
spec_mark "<!-- factory-human-check-issue -->"
touch "$FAKE_GH/labels-lag"
run
eq "spec stays open" open "$(spec_state)"
has "not found told" "check issue is not found yet" "$(log)"

setup "the marked check issue closed lets the spec close (#183)"
done_spec; ledger
check closed "- [ ] 환경 준비 표시 (PR #41)"
spec_mark "<!-- factory-human-check-issue -->"
spec_mark "<!-- factory-human-check-issue 850 -->"
run
eq "spec closed" closed "$(spec_state)"

setup "no ledger issue only warns"
spec 50 spec
run
eq code 0 "$(code)"
has "warns" "no open factory-ledger issue" "$(log)"

# --- Implementer tracks (#286) -------------------------------------------------------------

# implementing <n> <track> [status]: an Implementer run for ticket <n> in <track>, not completed
implementing() {
  local f="$FAKE_GH/runs-list.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg t "$2" --arg s "${3:-in_progress}" \
    '[{databaseId: (([.[].databaseId] | max // 1000) + 1), workflow: "factory-implementer.yml", status: $s,
       event: "workflow_dispatch", displayTitle: "implement #\($n) (track \($t))"}] + .' "$f" | tr -d '\r' > "$f.new" \
    && mv "$f.new" "$f"
}
tracks_of() { grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*track=\([0-9]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//'; }

setup "two empty tracks fill with the two lowest tickets"
issue 61 ready-for-agent; issue 62 ready-for-agent; issue 63 ready-for-agent
FACTORY_TRACKS=2 run --tickets-only
eq code 0 "$(code)"
eq "two tickets" "61 62" "$(dispatched)"
eq "one per track" "1 2" "$(tracks_of)"
has "says the tracks" "tracks: 2, empty: 1 2" "$(log)"

setup "FACTORY_TRACKS unset means two tracks"
issue 61 ready-for-agent; issue 62 ready-for-agent
unset FACTORY_TRACKS
run --tickets-only
eq "two tickets" "61 62" "$(dispatched)"
export FACTORY_TRACKS=1

setup "a bad FACTORY_TRACKS warns and means two"
issue 61 ready-for-agent; issue 62 ready-for-agent
FACTORY_TRACKS=x run
eq "two tickets" "61 62" "$(dispatched)"
has "warns" "FACTORY_TRACKS" "$(log)"

setup "the empty track only"
issue 61 ready-for-agent; issue 62 ready-for-agent
implementing 70 1
FACTORY_TRACKS=2 run
eq "one ticket" 61 "$(dispatched)"
eq "into track 2" 2 "$(tracks_of)"

setup "full tracks dispatch nothing"
issue 61 ready-for-agent
implementing 70 1; implementing 71 2 queued
FACTORY_TRACKS=2 run --candidates "61"
eq code 0 "$(code)"
eq "nothing" "" "$(dispatched)"
has "says so" "every track is busy" "$(log)"
lacks "no spec opened" "factory-decompose" "$(cat "$FAKE_GH/calls.log")"

setup "completed runs and this run do not hold a track"
issue 61 ready-for-agent; issue 62 ready-for-agent
implementing 70 1 completed; implementing 71 2
GITHUB_RUN_ID=$(jq '.[0].databaseId' "$FAKE_GH/runs-list.json" | tr -d '\r') FACTORY_TRACKS=2 run
eq "both tracks" "61 62" "$(dispatched)"

setup "a ticket with an Implementer run going is not dispatched again"
issue 61 ready-for-agent; issue 62 ready-for-agent
implementing 61 1
FACTORY_TRACKS=2 run --candidates "61"
eq "the other ticket" 62 "$(dispatched)"
has "says so" "#61 already has an implement run" "$(log)"

setup "calls one after another never dispatch a ticket twice"
issue 61 ready-for-agent; issue 62 ready-for-agent
FACTORY_TRACKS=3 run --candidates "61"
FACTORY_TRACKS=3 run --candidates "61"
FACTORY_TRACKS=3 run --first 61
eq "each once, a track left empty" "61 62" "$(dispatched)"
eq "dispatches" 2 "$(grep -c '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log")"

setup "--first goes before lower numbers"
issue 61 ready-for-agent; issue 64 ready-for-agent
run --first 64
eq "first" 64 "$(dispatched)"

setup "a run not listed yet only warns"
issue 61 ready-for-agent
touch "$FAKE_GH/runs-hidden"
FACTORY_TRACKS=2 run --tickets-only
eq code 0 "$(code)"
eq "dispatched" 61 "$(dispatched)"
has "warns" "::warning::" "$(log)"

# open <n> <tickets…>: spec <n> labelled `spec` with those tickets as its open sub-issues
open_spec() {
  local n=$1; shift
  jq -n --argjson n "$n" --argjson t "$#" \
    '{number: $n, state: "open", body: "", labels: [{name: "spec"}],
      sub_issues_summary: {total: ($t + 1), completed: 1}}' | tr -d '\r' > "$FAKE_GH/issue-$n.json"
  printf '%s\n' "$@" | jq -R '{number: tonumber}' | jq -s . | tr -d '\r' > "$FAKE_GH/sub-issues-$n.json"
}

setup "a free track opens the next spec of the queue"
open_spec 50 61; issue 61 in-progress; ledger; spec 60 ""; spec 61 ""
implementing 61 1
FACTORY_TRACKS=2 FACTORY_SPEC_QUEUE="60 61" run
eq code 0 "$(code)"
eq "no ticket" "" "$(dispatched)"
eq "decompose" 60 "$(decomposed)"

setup "as many specs as tracks: no next spec"
open_spec 50 61; issue 61 in-progress; open_spec 55 66; issue 66 ready-for-agent 1; ledger; spec 60 ""
implementing 61 1
FACTORY_TRACKS=2 FACTORY_SPEC_QUEUE="60" run
eq "no decompose" "" "$(decomposed)"
has "says so" "2 spec(s) running" "$(log)"

setup "FACTORY_TRACKS=1: a spec in progress blocks the next spec, as before"
open_spec 50 61; issue 61 in-progress; ledger; spec 60 ""
implementing 61 1
FACTORY_TRACKS=1 FACTORY_SPEC_QUEUE="60" run
eq "no ticket" "" "$(dispatched)"
eq "no decompose" "" "$(decomposed)"

setup "a spec or an issue with sub-issues is not a ticket"
issue 61 ready-for-agent,spec
issue 62 ready-for-agent
jq '.sub_issues_summary = {total: 3, completed: 0}' "$FAKE_GH/issue-62.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-62.json"
issue 63 ready-for-agent
run --tickets-only
eq code 0 "$(code)"
eq "only the plain ticket" 63 "$(dispatched)"

setup "FACTORY_TRACKS=1: one ticket per call, track 1"
issue 61 ready-for-agent; issue 62 ready-for-agent
FACTORY_TRACKS=1 run --tickets-only
eq "one" 61 "$(dispatched)"
eq "track 1" 1 "$(tracks_of)"

# --- idle after the last spec (#189) ---------------------------------------------------------
# spec #178 closed at 15:51:22 but the in-progress search still listed its ticket #179 (closed at
# 15:50:55, label removed 15:51:01): the ticket counted as a spec of its own and no idle marker came.

setup "a ticket the lagging search still lists as in-progress holds nothing: idle once (#189)"
done_spec; ledger; spec 60 spec closed
jq -n '{number: 61, state: "closed", body: "## Parent\n\n#50\n", labels: []}' | tr -d '\r' > "$FAKE_GH/issue-61.json"
issue 61 in-progress; mv "$FAKE_GH/issue-61.json" "$FAKE_GH/listed-61.json"
jq -n '{number: 61, state: "closed", body: "## Parent\n\n#50\n", labels: []}' | tr -d '\r' > "$FAKE_GH/issue-61.json"
FACTORY_SPEC_QUEUE="60 50" run
eq code 0 "$(code)"
eq "spec closed" closed "$(spec_state)"
lacks "not running" "spec(s) running" "$(log)"
eq "idle" "<!-- factory-idle 60-50 -->" "$(marked '<!-- factory-')"

setup "a ticket outside every spec holds idle; its close tells idle once (#189)"
done_spec; ledger; spec 60 spec closed
jq -n '{number: 70, state: "open", body: "", labels: [{name: "in-progress"}]}' | tr -d '\r' > "$FAKE_GH/issue-70.json"
FACTORY_SPEC_QUEUE="60 50" run
eq "spec closed" closed "$(spec_state)"
has "running" "1 spec(s) running" "$(log)"
eq "no idle yet" "" "$(marked '<!-- factory-')"
# #70 closes: the frontier run (--tickets-only) tells idle
jq '.state = "closed" | .labels = []' "$FAKE_GH/issue-70.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-70.json"
FACTORY_SPEC_QUEUE="60 50" run --tickets-only
eq code 0 "$(code)"
eq "idle" "<!-- factory-idle 60-50 -->" "$(marked '<!-- factory-')"
FACTORY_SPEC_QUEUE="60 50" run --tickets-only
FACTORY_SPEC_QUEUE="60 50" run
eq "once" "<!-- factory-idle 60-50 -->" "$(marked '<!-- factory-')"
eq "no decompose" "" "$(decomposed)"

setup "--tickets-only: an open spec or a pending queue spec is not idle (#189)"
open_spec 50 61; issue 61 in-progress; ledger
implementing 61 1
FACTORY_SPEC_QUEUE="50" run --tickets-only
eq "open spec" "" "$(marked '<!-- factory-')"
setup "--tickets-only: a queue spec not yet labelled is not idle and does not start (#189)"
ledger; spec 60 ""
FACTORY_SPEC_QUEUE="60" run --tickets-only
eq "pending" "" "$(marked '<!-- factory-')"
eq "no decompose" "" "$(decomposed)"

setup "a local ticket outside every spec holds nothing (#189)"
done_spec; ledger; spec 60 spec closed
jq -n '{number: 71, state: "open", body: "", labels: [{name: "ready-for-agent"}, {name: "local"}]}' | tr -d '\r' > "$FAKE_GH/issue-71.json"
FACTORY_SPEC_QUEUE="60" run
eq "idle" "<!-- factory-idle 60 -->" "$(marked '<!-- factory-')"

echo "dispatch-next.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
