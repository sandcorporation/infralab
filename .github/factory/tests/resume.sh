#!/usr/bin/env bash
# Tests of .github/factory/resume.sh (deciding the stopped stage of a spec) against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../resume.sh"
workflow="$here/../../workflows/factory-resume.yml"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_ROOT="$tmp/repo"
  export FACTORY_NOW=1794884400 # 2026-11-17T03:00:00Z = 12:00 KST
  export FACTORY_DISPATCH_NEXT="$tmp/dispatch-next.sh"
  unset FACTORY_SPEC_BUDGET_USD FACTORY_DAILY_BUDGET_USD
  mkdir -p "$FAKE_GH" "$FACTORY_ROOT/backend/tests"
  : > "$GITHUB_OUTPUT"
  : > "$FAKE_GH/calls.log"
  printf '#!/usr/bin/env bash\necho next >> "%s"\n' "$tmp/next.log" > "$FACTORY_DISPATCH_NEXT"
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}

# issue <n> <labels comma-separated> [body]
issue() {
  jq -n --argjson n "$1" --arg l "$2" --arg b "${3:-}" \
    '{number: $n, state: "open", title: "T\($n)", body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# subs <spec> <n:state> ...
subs() {
  local s=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {number: (.[0] | tonumber), state: .[1]}' | jq -s . \
    | tr -d '\r' > "$FAKE_GH/sub-issues-$s.json"
}

# pull <number> <state> <head ref> [body]
pull() {
  local f="$FAKE_GH/pulls.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg s "$2" --arg h "$3" --arg b "${4:-}" \
    '. + [{number: $n, state: $s, head: {ref: $h}, body: $b}]' "$f" | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

# A ticket's acceptance test in the checkout.
tested() { printf '@pytest.mark.skip(reason="#%s")\ndef test_t%s():\n    pass\n' "$1" "$1" >> "$FACTORY_ROOT/backend/tests/test_spec_x.py"; }

# ledger_comment <spec> <cost>: a ledger comment today (KST) on the ledger issue #900
ledger_comment() {
  local f="$FAKE_GH/comments-900.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg b "<!-- ledger -->
spec=#$1 node=implementer issue=#$1 run=1 cost=$2 turns=1 input=1 output=1 cache_read=0 cache_write=0" \
    '. + [{id: (length + 1), created_at: "2026-11-17T02:00:00Z", body: $b}]' "$f" | tr -d '\r' > "$f.new" \
    && mv "$f.new" "$f"
}

run() { bash "$script" "$1" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }
out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
code() { cat "$tmp/code"; }
dispatched() { grep 'actions/workflows/.*/dispatches' "$FAKE_GH/calls.log" | sed -n 's/.*workflows\/\([^/]*\)\/dispatches.*/\1/p' | tr '\n' ';'; }
nexts() { [ -f "$tmp/next.log" ] && wc -l < "$tmp/next.log" | tr -d ' ' || echo 0; }

# --- guard ---------------------------------------------------------------------------------

setup "a spec still labelled factory-paused does not resume"
issue 249 spec,factory-paused
run 249
eq code 0 "$(code)"
eq action skip "$(out action)"
eq dispatches "" "$(dispatched)"
eq next 0 "$(nexts)"

setup "a spec still labelled needs-decision does not resume"
issue 249 spec,needs-decision
run 249
eq action skip "$(out action)"
eq dispatches "" "$(dispatched)"

setup "a spec over its budget does not resume"
issue 249 spec "예산: \$10"
issue 900 factory-ledger
ledger_comment 249 12
run 249
eq action skip "$(out action)"
eq dispatches "" "$(dispatched)"

# --- decompose / odin ----------------------------------------------------------------------

setup "a spec without sub-issues is decomposed again"
issue 249 spec
run 249
eq code 0 "$(code)"
eq action decompose "$(out action)"
eq dispatches "factory-decompose.yml;" "$(dispatched)"
eq input 1 "$(grep -c 'inputs\[issue\]=249' "$FAKE_GH/calls.log")"

setup "open tickets without acceptance tests are decomposed again"
issue 249 spec
subs 249 301:open 302:open
tested 301
run 249
eq action decompose "$(out action)"
eq dispatches "factory-decompose.yml;" "$(dispatched)"

setup "an open spec PR goes to Odin"
issue 249 spec
subs 249 301:open
pull 43 open factory/spec-249
run 249
eq code 0 "$(code)"
eq action odin "$(out action)"
eq dispatches "factory-odin.yml;" "$(dispatched)"
eq input 1 "$(grep -c 'inputs\[spec\]=249' "$FAKE_GH/calls.log")"

setup "a failed Odin dispatch only warns"
issue 249 spec
pull 43 open factory/spec-249
touch "$FAKE_GH/fail-dispatch"
run 249
eq code 0 "$(code)"
eq action odin "$(out action)"

# --- approved tickets ----------------------------------------------------------------------

setup "an in-progress ticket with the Implementer's checked PR goes to Verify"
issue 249 spec
subs 249 301:closed 302:open 303:open
tested 302; tested 303
issue 302 in-progress
issue 303 ready-for-agent
pull 60 open factory/issue-303 "Closes #303

<!-- factory-checked abc -->"
pull 61 open factory/issue-302 "Closes #302

<!-- factory-checked def -->"
run 249
eq code 0 "$(code)"
eq action verify "$(out action)"
eq dispatches "factory-verify.yml;" "$(dispatched)"
eq "inputs" 1 "$(grep -c 'inputs\[issue\]=302 -f inputs\[pr\]=61' "$FAKE_GH/calls.log")"
eq next 0 "$(nexts)"

setup "an in-progress ticket whose PR is not checked yet continues the chain"
issue 249 spec
subs 249 302:open
tested 302
issue 302 in-progress
pull 61 open factory/issue-302 "Closes #302"
run 249
eq action next "$(out action)"
eq dispatches "" "$(dispatched)"
eq next 1 "$(nexts)"

setup "a checked PR of another ticket (#3020) does not count for #302"
issue 249 spec
subs 249 302:open
tested 302
issue 302 in-progress
pull 61 open factory/issue-3020 "Closes #3020

<!-- factory-checked def -->"
pull 62 closed factory/issue-302 "Closes #302

<!-- factory-checked def -->"
run 249
eq action next "$(out action)"
eq dispatches "" "$(dispatched)"

setup "approved tickets without a PR continue the chain"
issue 249 spec
subs 249 301:open 302:open
tested 301; tested 302
issue 301 ready-for-agent
issue 302 ready-for-agent
run 249
eq code 0 "$(code)"
eq action next "$(out action)"
eq next 1 "$(nexts)"

setup "a failed Verify dispatch fails the run"
issue 249 spec
subs 249 302:open
tested 302
issue 302 in-progress
pull 61 open factory/issue-302 "Closes #302 <!-- factory-checked def -->"
touch "$FAKE_GH/fail-dispatch"
run 249
eq code 1 "$(code)"

# --- workflow ------------------------------------------------------------------------------

current="workflow: unlabeled trigger for the two stop labels on spec issues"
eq "unlabeled" 1 "$(grep -c 'types: \[unlabeled\]' "$workflow")"
eq "needs-decision" 1 "$(grep -c "github.event.label.name == 'needs-decision'" "$workflow")"
eq "factory-paused" 1 "$(grep -c "github.event.label.name == 'factory-paused'" "$workflow")"
eq "spec label" 1 "$(grep -c "contains(github.event.issue.labels.\*.name, 'spec')" "$workflow")"
eq "script" 1 "$(grep -c 'resume.sh "\$SPEC"' "$workflow")"

echo "resume.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
