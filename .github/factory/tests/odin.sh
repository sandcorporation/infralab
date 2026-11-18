#!/usr/bin/env bash
# Tests of .github/factory/odin.sh (state, verdict and wrap-up of the Odin stage) against the fake gh.
# The chain is started by the real dispatch-next.sh (--tickets-only), so these tests also pin which
# ticket goes first after the merge.
set -u
here=$(cd "$(dirname "$0")" && pwd)
odin="$here/../odin.sh"
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

# issue <n> <labels csv> [blocked_by] [body]
issue() {
  jq -n --argjson n "$1" --arg l "$2" --argjson b "${3:-0}" --arg body "${4:-}" \
    '{number: $n, state: "open", body: $body,
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      issue_dependencies_summary: {blocked_by: $b}}' > "$FAKE_GH/issue-$1.json"
}
ticket() { # ticket <n> [blocked_by]: a ticket of spec #50
  issue "$1" "model:sonnet" "${2:-0}" "## Parent

#50

## What to build
x"
}

# setup <name> [changed files]: spec #50 with tickets #61 (blocked by one open issue), #62, #63 and
# the open spec PR #70 (head factory/spec-50).
setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FACTORY_TRACKS=1 FACTORY_DISPATCH_SEEN_WAIT=0 FACTORY_LIST_RETRY_WAIT=0 FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_MERGE_WAIT=0 RUN_URL=https://example.invalid/run/1
  unset FACTORY_DISPATCH_NEXT
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  : > "$GITHUB_OUTPUT"
  issue 50 spec
  ticket 61 1
  ticket 62
  ticket 63
  issue 64 "" 0 "## Parent

#50"
  jq '.state = "closed"' "$FAKE_GH/issue-64.json" > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-64.json"
  jq -n '[{number: 61, state: "open"}, {number: 62, state: "open"}, {number: 63, state: "open"},
          {number: 64, state: "closed"}]' > "$FAKE_GH/sub-issues-50.json"
  jq -n '[{number: 70, state: "open", title: "스펙", body: "Refs #50", head: {ref: "factory/spec-50"}}]' \
    > "$FAKE_GH/pulls.json"
  jq -n --argjson c "${2:-2}" \
    '{number: 70, state: "open", merged: false, changed_files: $c, head: {ref: "factory/spec-50"}}' \
    > "$FAKE_GH/pull-70.json"
  jq -n '{number: 70, state: "open", body: "", labels: [{name: "spec-pr"}], pull_request: {}}' \
    > "$FAKE_GH/issue-70.json"
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
calls() { cat "$FAKE_GH/calls.log"; }
labels_of() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
approved() { # tickets labelled ready-for-agent, ascending
  local n r=
  for n in 61 62 63 64; do
    case ",$(labels_of "$n")," in *,ready-for-agent,*) r="$r $n" ;; esac
  done
  echo "${r# }"
}
dispatched() { grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }
merged() { jq -r '.merged' "$FAKE_GH/pull-70.json" | tr -d '\r'; }
pr_comments() { jq -r '.[].body' "$FAKE_GH/comments-70.json" 2> /dev/null | tr -d '\r'; }
spec_comments() { jq -r '.[].body' "$FAKE_GH/comments-50.json" 2> /dev/null | tr -d '\r'; }

# --- state ---------------------------------------------------------------------------------------

setup state-review
bash "$odin" state 50 > /dev/null
eq "mode" review "$(out mode)"
eq "pr" 70 "$(out pr)"
eq "branch" factory/spec-50 "$(out branch)"

setup state-empty 0
bash "$odin" state 50 > /dev/null
eq "mode" empty "$(out mode)"
eq "pr" 70 "$(out pr)"

setup state-none
echo '[]' > "$FAKE_GH/pulls.json"
msg=$(bash "$odin" state 50 2>&1)
eq "mode" none "$(out mode)"
eq "no pr" "" "$(out pr)"
has "warns" "::warning::" "$msg"

setup state-other-branch
jq -n '[{number: 71, state: "open", head: {ref: "factory/spec-5"}}]' > "$FAKE_GH/pulls.json"
bash "$odin" state 50 > /dev/null 2>&1
eq "another spec's PR is not ours" none "$(out mode)"

# --- verdict -------------------------------------------------------------------------------------

for v in pass fixed question nonsense; do
  setup "verdict-$v"
  echo "$v" > "$tmp/verdict"
  bash "$odin" verdict 50 "$tmp/verdict" > /dev/null 2>&1
  case $v in pass | fixed) want=go ;; question) want=question ;; *) want=missing ;; esac
  eq "verdict" "$want" "$(out verdict)"
done

setup verdict-missing-file
bash "$odin" verdict 50 "$tmp/nothing" > /dev/null 2>&1
eq "verdict" missing "$(out verdict)"

setup verdict-label-wins
issue 50 spec,needs-decision
echo pass > "$tmp/verdict"
bash "$odin" verdict 50 "$tmp/verdict" > /dev/null
eq "needs-decision makes it a question" question "$(out verdict)"

# --- question: nothing merged, nothing approved ---------------------------------------------------

setup question
issue 50 spec,needs-decision
printf '### 결함\n메뉴 자리가 갈린다\n' > "$tmp/report.md"
bash "$odin" question 50 70 "$tmp/report.md" > /dev/null
eq "exit" 0 "$?"
eq "not merged" false "$(merged)"
eq "no ticket approved" "" "$(approved)"
eq "nothing dispatched" "" "$(dispatched)"
lacks "no merge call" "/merge" "$(calls)"
has "report on the PR" "메뉴 자리가 갈린다" "$(pr_comments)"
eq "spec keeps needs-decision" "needs-decision,spec" "$(labels_of 50)"

# --- pass: merge, approve, dispatch the lowest unblocked ticket -----------------------------------

runs_left() { jq -r '[.[].id] | join(",")' "$FAKE_GH/runs.json" | tr -d '
'; }

setup pass
jq -n '[{id: 1, event: "pull_request", head_branch: "factory/spec-50", triggering_actor: {login: "github-actions[bot]"}, jobs: 0}]' | tr -d '
' > "$FAKE_GH/runs.json"
printf -- '- 이름 불일치 하나를 고쳤다\n' > "$tmp/report.md"
bash "$odin" pass 50 70 "$tmp/report.md" > "$tmp/log" 2>&1
eq "exit" 0 "$?"
eq "merged" true "$(merged)"
has "squash" "pulls/70/merge -f merge_method=squash" "$(calls)"
has "branch deleted" "git/refs/heads/factory/spec-50" "$(calls)"
eq "bot pull_request run deleted (#270)" "" "$(runs_left)"
has "main built" "actions/workflows/ci.yml/dispatches" "$(calls)"
eq "open tickets approved" "61 62 63" "$(approved)"
# #61 is blocked (an open blocker); #62 is the lowest-numbered unblocked ticket.
eq "first dispatch" 62 "$(dispatched)"
has "report on the PR" "이름 불일치 하나를 고쳤다" "$(pr_comments)"
eq "spec untouched" spec "$(labels_of 50)"
# The merge happens before any ticket is approved.
merge_line=$(grep -n '/merge' "$FAKE_GH/calls.log" | head -n 1 | cut -d: -f1)
label_line=$(grep -n 'labels\[\]=ready-for-agent' "$FAKE_GH/calls.log" | head -n 1 | cut -d: -f1)
if [ -n "$merge_line" ] && [ -n "$label_line" ] && [ "$merge_line" -lt "$label_line" ]; then ok; else
  bad "merge ($merge_line) before ready-for-agent ($label_line)"
fi

setup pass-search-lags
# The label search does not see the labels just added (#267): the approved tickets are named.
touch "$FAKE_GH/list-empty"
bash "$odin" pass 50 70 > "$tmp/log" 2>&1
eq "exit" 0 "$?"
eq "open tickets approved" "61 62 63" "$(approved)"
eq "first dispatch despite the empty search" 62 "$(dispatched)"
lacks "no second search" "asking again" "$(cat "$tmp/log")"

setup pass-all-blocked
ticket 62 1
ticket 63 2
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "exit" 0 "$?"
eq "approved anyway" "61 62 63" "$(approved)"
eq "nothing to dispatch" "" "$(dispatched)"

setup pass-paused-spec
issue 50 spec,factory-paused
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "a paused spec's ticket does not start" "" "$(dispatched)"

setup merge-fails
touch "$FAKE_GH/fail-merge"
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "exit" 1 "$?"
eq "not merged" false "$(merged)"
eq "no ticket approved" "" "$(approved)"
eq "nothing dispatched" "" "$(dispatched)"
lacks "branch kept" "git/refs/heads/factory/spec-50" "$(calls)"

# --- empty spec PR --------------------------------------------------------------------------------

setup empty 0
jq -n '[{id: 1, event: "pull_request", head_branch: "factory/spec-50", triggering_actor: {login: "github-actions[bot]"}, jobs: 0}]' | tr -d '
' > "$FAKE_GH/runs.json"
bash "$odin" empty 50 70 > /dev/null 2>&1
eq "exit" 0 "$?"
eq "closed" closed "$(jq -r .state "$FAKE_GH/pull-70.json" | tr -d '\r')"
eq "not merged" false "$(merged)"
has "branch deleted" "git/refs/heads/factory/spec-50" "$(calls)"
eq "bot pull_request run deleted (#270)" "" "$(runs_left)"
eq "open tickets approved" "61 62 63" "$(approved)"
eq "first dispatch" 62 "$(dispatched)"
has "says why" "인수 시험 0개" "$(pr_comments)"

# --- two failed checks: a human ---------------------------------------------------------------

setup human
printf '### scripts/ci.sh all 실패\nerror: unused variable\n' > "$tmp/reason.md"
bash "$odin" human 50 70 "$tmp/reason.md" > /dev/null 2>&1
eq "exit" 0 "$?"
eq "spec to a human" "ready-for-human,spec" "$(labels_of 50)"
has "human marker" "<!-- factory-human -->" "$(spec_comments)"
has "reason on the spec" "error: unused variable" "$(spec_comments)"
has "reason on the PR" "error: unused variable" "$(pr_comments)"
eq "not merged" false "$(merged)"
eq "no ticket approved" "" "$(approved)"
eq "nothing dispatched" "" "$(dispatched)"

has "PR hand-over marker (#359)" "<!-- factory-odin-human -->" "$(pr_comments)"

# --- conflicts with main (#359) ---------------------------------------------------------------

odin_dispatches() { grep -c 'factory-odin.yml/dispatches' "$FAKE_GH/calls.log" | tr -d '\r'; }
conflict_comments() { jq -r '[.[] | select(.body | startswith("<!-- factory-odin-conflict -->"))] | length' \
  "$FAKE_GH/comments-70.json" 2> /dev/null | tr -d '\r'; }
conflict_files() { printf 'backend/cohorts/models.py\nweb/src/api.ts\n' > "$tmp/files"; }
# comment_on_70 <body> [login]: a comment already on the spec PR (by the factory unless a login is given)
comment_on_70() {
  f="$FAKE_GH/comments-70.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg b "$1" --arg u "${2:-github-actions[bot]}" \
    '. +[{id: (length + 1), created_at: "2026-11-17T01:00:00Z", body: $b, user: {login: $u}}]' "$f" > "$f.new" \
    && mv "$f.new" "$f"
}

setup conflict-first-round
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "exit" 0 "$?"
eq "resolve" true "$(out resolve)"
eq "round counted on the PR" 1 "$(conflict_comments)"
has "files on the PR" "backend/cohorts/models.py" "$(pr_comments)"
has "round of limit" "풀기 1/2" "$(pr_comments)"
eq "no dispatch without --dispatch" 0 "$(odin_dispatches)"
eq "spec untouched" spec "$(labels_of 50)"

setup conflict-resolved-then-merged
# The checkout conflicts, the agent resolves, the checks pass: the merge goes through.
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "resolve" true "$(out resolve)"
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "pass exit" 0 "$?"
eq "merged" true "$(merged)"
eq "open tickets approved" "61 62 63" "$(approved)"
eq "first dispatch" 62 "$(dispatched)"
eq "no human" spec "$(labels_of 50)"

setup conflict-merge-fails-dispatches-a-round
# The squash merge fails (main moved again): the next round runs as a new Odin run in conflict mode.
touch "$FAKE_GH/fail-merge"
conflict_files
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "pass exit" 1 "$?"
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" --dispatch > /dev/null 2>&1
eq "exit" 0 "$?"
eq "resolve" true "$(out resolve)"
eq "one Odin run dispatched" 1 "$(odin_dispatches)"
has "conflict mode" "inputs[mode]=conflict" "$(grep 'factory-odin.yml/dispatches' "$FAKE_GH/calls.log")"
has "same spec" "inputs[spec]=50" "$(grep 'factory-odin.yml/dispatches' "$FAKE_GH/calls.log")"
# The dispatched run resolves and merges.
rm "$FAKE_GH/fail-merge"
bash "$odin" pass 50 70 > /dev/null 2>&1
eq "merged on the next round" true "$(merged)"
eq "no human" spec "$(labels_of 50)"

setup conflict-limit-goes-to-a-human
# Every merge attempt fails: two rounds, then a human with the conflicting files.
touch "$FAKE_GH/fail-merge"
conflict_files
for round in 1 2; do
  bash "$odin" pass 50 70 > /dev/null 2>&1
  bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" --dispatch > /dev/null 2>&1
  eq "round $round exit" 0 "$?"
done
bash "$odin" pass 50 70 > /dev/null 2>&1
: > "$GITHUB_OUTPUT"
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" --dispatch > /dev/null 2>&1
eq "third round refused" 1 "$?"
eq "resolve" false "$(out resolve)"
eq "rounds stay at the limit" 2 "$(conflict_comments)"
eq "no third dispatch" 2 "$(odin_dispatches)"
has "limit in the reason" "한도(2회)" "$(cat "$tmp/reason.md")"
has "files in the reason" "web/src/api.ts" "$(cat "$tmp/reason.md")"
bash "$odin" human 50 70 "$tmp/reason.md" > /dev/null 2>&1
eq "spec to a human" "ready-for-human,spec" "$(labels_of 50)"
has "files on the spec" "backend/cohorts/models.py" "$(spec_comments)"
eq "not merged" false "$(merged)"
eq "no ticket approved" "" "$(approved)"

setup conflict-limit-from-env
ODIN_CONFLICT_LIMIT=1 bash "$odin" conflict 50 70 /dev/null "$tmp/reason.md" > /dev/null 2>&1
eq "first round under a limit of 1" 0 "$?"
ODIN_CONFLICT_LIMIT=1 bash "$odin" conflict 50 70 /dev/null "$tmp/reason.md" > /dev/null 2>&1
eq "second round over a limit of 1" 1 "$?"
has "no files known" "GitHub이 병합을 거절했다" "$(cat "$tmp/reason.md")"

setup conflict-counts-after-a-human
# A person fixed the PR after a hand-over and ran Odin again: the rounds start over.
comment_on_70 "<!-- factory-odin-conflict -->
round"
comment_on_70 "<!-- factory-odin-conflict -->
round"
comment_on_70 "<!-- factory-odin-human -->
Odin: 병합하지 않음"
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "rounds start over after a human" 0 "$?"
has "round 1 again" "풀기 1/2" "$(pr_comments)"

setup conflict-old-rounds-count
comment_on_70 "<!-- factory-odin-conflict -->
round"
comment_on_70 "<!-- factory-odin-conflict -->
round"
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "earlier runs' rounds count" 1 "$?"

setup conflict-markers-by-others-do-not-count
# Anyone can comment on a public repository: neither a stranger's rounds nor a stranger's hand-over count.
comment_on_70 "<!-- factory-odin-conflict -->
round"
comment_on_70 "<!-- factory-odin-conflict -->
round"
comment_on_70 "<!-- factory-odin-human -->
reset" someone
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "a stranger's hand-over does not reset" 1 "$?"
setup conflict-stranger-rounds
comment_on_70 "<!-- factory-odin-conflict -->
round" someone
comment_on_70 "<!-- factory-odin-conflict -->
round" someone
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" > /dev/null 2>&1
eq "a stranger's rounds do not count" 0 "$?"

setup conflict-dispatch-fails
touch "$FAKE_GH/fail-dispatch"
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" --dispatch > /dev/null 2>&1
eq "a failed dispatch goes to a human" 1 "$?"
eq "resolve" false "$(out resolve)"
has "says so" "dispatch" "$(cat "$tmp/reason.md")"

setup conflict-comment-fails
touch "$FAKE_GH/fail-comments"
conflict_files
bash "$odin" conflict 50 70 "$tmp/files" "$tmp/reason.md" --dispatch > /dev/null 2>&1
eq "an uncounted round goes to a human" 1 "$?"
eq "nothing dispatched" 0 "$(odin_dispatches)"

setup usage
bash "$odin" pass 50 > /dev/null 2>&1
eq "usage exit" 2 "$?"
bash "$odin" conflict 50 70 "$tmp/files" > /dev/null 2>&1
eq "conflict usage exit" 2 "$?"

echo "odin.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
