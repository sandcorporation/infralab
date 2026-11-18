#!/usr/bin/env bash
# Tests of .github/factory/decompose.sh (state and wrap-up of the Decompose stage) against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../decompose.sh"
workflow="$here/../../workflows/factory-decompose.yml"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# --- helpers -------------------------------------------------------------------------------

g() { git -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false "$@"; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_ROOT="$tmp/repo" FACTORY_APP_TOKEN=app-token
  mkdir -p "$FAKE_GH"
  : > "$GITHUB_OUTPUT"
  # A checkout of main with one merged acceptance test (ticket #301) and a bare origin.
  g init -q --bare "$tmp/origin.git"
  g init -q -b main "$FACTORY_ROOT"
  mkdir -p "$FACTORY_ROOT/backend/tests" "$FACTORY_ROOT/backend/app" "$FACTORY_ROOT/web/src/spec" "$FACTORY_ROOT/agent"
  printf 'import pytest\n\n\n@pytest.mark.skip(reason="#301")\ndef test_a():\n    pass\n' \
    > "$FACTORY_ROOT/backend/tests/test_spec_old_app.py"
  echo '# app' > "$FACTORY_ROOT/backend/app/models.py"
  (cd "$FACTORY_ROOT" && g add -A && g commit -q -m init && g remote add origin "$tmp/origin.git" \
    && g push -q origin main)
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}

# issue <n> <labels comma-separated> [title]
issue() {
  jq -n --argjson n "$1" --arg l "$2" --arg t "${3:-Ticket $1}" --arg b "${4:-}" \
    '{number: $n, state: "open", title: $t, body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# subs <spec> <n:state> ...
subs() {
  local s=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {number: (.[0] | tonumber), state: .[1]}' | jq -s . \
    | tr -d '\r' > "$FAKE_GH/sub-issues-$s.json"
}

# pull <number> <state> <head ref>
pull() {
  local f="$FAKE_GH/pulls.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg s "$2" --arg h "$3" '. + [{number: $n, state: $s, head: {ref: $h}}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
labels_of() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
pull_count() { [ -f "$FAKE_GH/pulls.json" ] && jq length "$FAKE_GH/pulls.json" | tr -d '\r' || echo 0; }
dispatches() { grep -c 'actions/workflows/factory-odin.yml/dispatches' "$FAKE_GH/calls.log" 2> /dev/null || true; }
remote_branch() { git -C "$tmp/origin.git" rev-parse -q --verify "refs/heads/factory/spec-$1" > /dev/null && echo yes || echo no; }

state() { bash "$script" state "$1" > "$tmp/log" 2>&1; }
finish() { bash "$script" finish "$1" "$2" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }

# --- state ---------------------------------------------------------------------------------

setup "state: a spec without sub-issues is new"
issue 249 spec "공장 개선"
state 249
eq mode new "$(out mode)"

setup "state: needs-decision waits for the answer"
issue 249 spec,needs-decision
subs 249 301:open
state 249
eq mode question "$(out mode)"

setup "state: an open spec PR means Odin only, even with tickets lacking tests"
issue 249 spec
subs 249 301:open 302:open
pull 41 closed factory/spec-249
pull 42 open factory/spec-250
pull 43 open factory/spec-249
state 249
eq mode specpr "$(out mode)"
eq pr 43 "$(out pr)"

setup "state: closed or other specs' PRs do not count"
issue 249 spec
pull 41 closed factory/spec-249
pull 42 open factory/spec-250
state 249
eq mode new "$(out mode)"

setup "state: open tickets without an ignore marker in the checkout are decomposed"
issue 249 spec
subs 249 301:open 302:open 303:closed 304:open
printf 'func TestB(t *testing.T) {\n\tt.Skip("#304")\n}\n' > "$FACTORY_ROOT/agent/spec_new_x_test.go"
state 249
eq mode decomposed "$(out mode)"
eq tickets 302 "$(out tickets)"

setup "state: a web marker counts, a marker outside the spec files does not"
issue 249 spec
subs 249 301:open 302:open 303:open
printf 'it.skip("b", () => { // #302\n});\n' > "$FACTORY_ROOT/web/src/spec/spec_new_x.test.ts"
printf '@pytest.mark.skip(reason="#303")\n' > "$FACTORY_ROOT/backend/tests/test_other.py"
state 249
eq mode decomposed "$(out mode)"
eq tickets 303 "$(out tickets)"

setup "state: a marker of a longer number does not count (#30 vs #301)"
issue 249 spec
subs 249 30:open
state 249
eq mode decomposed "$(out mode)"
eq tickets 30 "$(out tickets)"

setup "state: every open ticket has its tests: done"
issue 249 spec
subs 249 301:open 302:closed
state 249
eq mode done "$(out mode)"

# --- finish --------------------------------------------------------------------------------

setup "finish: a question (new spec) leaves no PR, branch, dispatch or ready-for-agent"
issue 249 spec,needs-decision
echo '# test' > "$FACTORY_ROOT/backend/tests/test_spec_x_app.py"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result question "$(out result)"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"
eq branch no "$(remote_branch 249)"

setup "finish: a ticket that changes workflow files becomes ready-for-human + local"
issue 249 spec,needs-decision
issue 301 model:sonnet "CI 에 단계를 더한다" "<!-- factory-touches-workflows -->"
issue 302 model:sonnet
subs 249 301:open 302:open
finish 249 decomposed
eq "#301 labels" "model:sonnet,local,ready-for-human" "$(labels_of 301)"
eq "#302 labels" "model:sonnet" "$(labels_of 302)"

setup "finish: a question (decomposed spec) also takes ready-for-agent off the open tickets"
issue 249 spec,needs-decision
issue 301 ready-for-agent,model:sonnet
issue 302 ready-for-agent
issue 303 ready-for-agent
subs 249 301:open 302:open 303:closed
finish 249 decomposed
eq result question "$(out result)"
eq "#301 labels" model:sonnet "$(labels_of 301)"
eq "#302 labels" "" "$(labels_of 302)"
eq "closed #303 labels" ready-for-agent "$(labels_of 303)"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"

setup "finish: a new spec gets the spec PR with only its acceptance tests, then Odin"
issue 249 spec "비용 장부"
issue 301 model:sonnet
issue 302 model:opus
subs 249 301:open 302:open
echo '# test' > "$FACTORY_ROOT/backend/tests/test_spec_ledger_app.py"
echo '// test' > "$FACTORY_ROOT/web/src/spec/spec_ledger_app.test.ts"
echo '// test' > "$FACTORY_ROOT/agent/spec_ledger_app_test.go"
echo '# stray' >> "$FACTORY_ROOT/backend/app/models.py"
echo '// stray' > "$FACTORY_ROOT/web/src/spec_misplaced.test.ts"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result pr "$(out result)"
eq pr 500 "$(out pr)"
eq title "스펙: 비용 장부 인수 시험 (#249)" "$(jq -r '.[0].title' "$FAKE_GH/pulls.json" | tr -d '\r')"
eq head factory/spec-249 "$(jq -r '.[0].head.ref' "$FAKE_GH/pulls.json" | tr -d '\r')"
eq base main "$(jq -r '.[0].base.ref' "$FAKE_GH/pulls.json" | tr -d '\r')"
body=$(jq -r '.[0].body' "$FAKE_GH/pulls.json" | tr -d '\r')
has "body" "Refs #249" "$body"
has "body" "- #301" "$body"
has "body" "- #302" "$body"
eq "PR labels" spec-pr "$(labels_of 500)"
eq "#301 labels" model:sonnet "$(labels_of 301)"
eq dispatches 1 "$(dispatches)"
has "dispatch input" "inputs[spec]=249" "$(grep dispatches "$FAKE_GH/calls.log")"
eq branch yes "$(remote_branch 249)"
eq "committed files" "agent/spec_ledger_app_test.go backend/tests/test_spec_ledger_app.py web/src/spec/spec_ledger_app.test.ts" \
  "$(git -C "$tmp/origin.git" diff --name-only main factory/spec-249 | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
has "misplaced test left out" "web/src/spec_misplaced.test.ts" "$(cat "$tmp/log")"
has "stray warning" "outside the acceptance tests" "$(cat "$tmp/log")"

setup "finish: a decomposed spec takes ready-for-agent off and opens the spec PR"
issue 249 spec
issue 301 ready-for-agent
issue 302 ready-for-agent,model:opus
subs 249 301:open 302:open
echo '# test' > "$FACTORY_ROOT/backend/tests/test_spec_ledger_more.py"
finish 249 decomposed
eq result pr "$(out result)"
eq "#301 labels" "" "$(labels_of 301)"
eq "#302 labels" model:opus "$(labels_of 302)"
eq dispatches 1 "$(dispatches)"

setup "finish: a new spec keeps existing ready-for-agent off its hands (only decomposed removes)"
issue 249 spec
issue 301 ""
subs 249 301:open
echo '# test' > "$FACTORY_ROOT/backend/tests/test_spec_a_b.py"
finish 249 new
eq "#301 labels" "" "$(labels_of 301)"
eq "no label added" 0 "$(grep -c 'issues/301/labels' "$FAKE_GH/calls.log" || true)"

setup "finish: a failed Odin dispatch only warns"
issue 249 spec
issue 301 ""
subs 249 301:open
echo '# test' > "$FACTORY_ROOT/backend/tests/test_spec_a_b.py"
touch "$FAKE_GH/fail-dispatch"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result pr "$(out result)"
has "warning" "could not dispatch factory-odin.yml" "$(cat "$tmp/log")"

setup "finish: no open tickets after a new decompose is an error, without a PR"
issue 249 spec
finish 249 new
eq code 1 "$(cat "$tmp/code")"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"

setup "dispatch-odin: dispatches factory-odin.yml with the spec"
issue 249 spec
bash "$script" dispatch-odin 249 > "$tmp/log" 2>&1
eq code 0 "$?"
eq dispatches 1 "$(dispatches)"

# --- create-tickets (#185) -----------------------------------------------------------------

create() { bash "$script" create-tickets "$@" > "$tmp/stdout" 2> "$tmp/log"; echo $? > "$tmp/code"; }
body_of() { jq -r '.body' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
subs_of() { jq -r '[.[].number] | join(" ")' "$FAKE_GH/sub-issues-$1.json" | tr -d '\r'; }
blockers_of() { [ -f "$FAKE_GH/blocked-by-$1.json" ] && jq -r '[.[].number] | join(" ")' "$FAKE_GH/blocked-by-$1.json" | tr -d '\r'; }
issue_count() { ls "$FAKE_GH"/issue-*.json | wc -l | tr -d ' '; }
tickets_json() { # three tickets: a (opus), b blocked by a, c (workflow file) blocked by a, b and #250
  echo '## What to build

B 를 만든다.' > "$tmp/b.md"
  jq -n --arg bf "$tmp/b.md" '[
    {key: "a", title: "A 를 깐다", body: "## What to build\n\nA.", model: "opus"},
    {key: "b", title: "B 를 얹는다", body_file: $bf, blocked_by: ["a"]},
    {key: "c", title: "CI 단계", body: "## What to build\n\nCI.", local: "workflows", blocked_by: ["a", "b", 250]}
  ]' > "$tmp/tickets.json"
}

setup "create-tickets: creates, links and labels every ticket, blockers first"
issue 249 spec "공장 개선"
issue 250 "" "앞 티켓"
tickets_json
create 249 "$tmp/tickets.json"
eq code 0 "$(cat "$tmp/code")"
eq stdout "#802 a A 를 깐다|#803 b B 를 얹는다|#804 c CI 단계" "$(tr '\n' '|' < "$tmp/stdout" | sed 's/|$//')"
eq "sub-issues" "802 803 804" "$(subs_of 249)"
eq "#802 blockers" "" "$(blockers_of 802)"
eq "#803 blockers" "802" "$(blockers_of 803)"
eq "#804 blockers" "802 803 250" "$(blockers_of 804)"
eq "#802 labels" "model:opus" "$(labels_of 802)"
eq "#803 labels" "model:sonnet" "$(labels_of 803)"
eq "#804 labels" "local,ready-for-human" "$(labels_of 804)"
has "#804 local comment" "<!-- factory-local -->" "$(cat "$FAKE_GH/comments-804.json")"
b=$(body_of 803)
has "#803 parent" "## Parent

#249" "$b"
has "#803 body" "B 를 만든다." "$b"
has "#803 blocked by" "## Blocked by

#802" "$b"
has "#803 marker" "<!-- factory-ticket spec=249 -->" "$b"
has "#802 no blockers" "None (can start immediately)" "$(body_of 802)"
b=$(body_of 804)
has "#804 blocked by" "#802, #803, #250" "$b"
has "#804 local line" "workflow 파일 — 로컬 작업자 몫" "$b"
has "#804 local marker" "<!-- factory-touches-workflows -->" "$b"
eq "no ready-for-agent" 0 "$(grep -c 'ready-for-agent' "$FAKE_GH/calls.log" || true)"

setup "create-tickets: running again creates no duplicates"
issue 249 spec
issue 250 ""
tickets_json
create 249 "$tmp/tickets.json"
before=$(issue_count)
create 249 "$tmp/tickets.json"
eq code 0 "$(cat "$tmp/code")"
eq "issues" "$before" "$(issue_count)"
eq stdout "#802 a A 를 깐다|#803 b B 를 얹는다|#804 c CI 단계" "$(tr '\n' '|' < "$tmp/stdout" | sed 's/|$//')"
eq "sub-issues" "802 803 804" "$(subs_of 249)"
eq "#804 blockers" "802 803 250" "$(blockers_of 804)"

setup "create-tickets: a partial failure names what exists, and a rerun finishes it"
issue 249 spec
issue 250 ""
tickets_json
touch "$FAKE_GH/fail-blocked-by"
create 249 "$tmp/tickets.json"
eq code 1 "$(cat "$tmp/code")"
eq stdout "#802 a A 를 깐다" "$(cat "$tmp/stdout" | tr -d '\r')"
has "error" "#802(a) #803(b, incomplete)" "$(cat "$tmp/log")"
has "rerun hint" "Run the same command again" "$(cat "$tmp/log")"
eq "no third issue" no "$([ -f "$FAKE_GH/issue-804.json" ] && echo yes || echo no)"
rm "$FAKE_GH/fail-blocked-by"
create 249 "$tmp/tickets.json"
eq code 0 "$(cat "$tmp/code")"
eq "issues" 5 "$(issue_count)"
eq "#803 blockers" "802" "$(blockers_of 803)"
eq "sub-issues" "802 803 804" "$(subs_of 249)"

setup "create-tickets: a ticket of another spec with the same title is not reused"
issue 249 spec
issue 700 "" "A 를 깐다" "<!-- factory-ticket spec=248 -->"
jq -n '[{title: "A 를 깐다", body: "x"}]' > "$tmp/t.json"
create 249 "$tmp/t.json"
eq code 0 "$(cat "$tmp/code")"
eq stdout "#802 1 A 를 깐다" "$(cat "$tmp/stdout" | tr -d '\r')"

setup "create-tickets: a bad file creates nothing"
issue 249 spec
jq -n '[{key: "a", title: "A", body: "x", model: "fable"},
  {key: "b", title: "B", body: "x", blocked_by: ["z"]},
  {key: "c", title: "", body: "x"}, {key: "d", title: "D", body: "x", local: "docs"}]' > "$tmp/t.json"
create 249 "$tmp/t.json"
eq code 2 "$(cat "$tmp/code")"
log=$(cat "$tmp/log")
has "model" "ticket a: model must be sonnet or opus" "$log"
has "blocker" "ticket b: blocker z" "$log"
has "title" "ticket c: no title" "$log"
has "local" "ticket d: local must be workflows or claude" "$log"
eq "issues" 1 "$(issue_count)"

setup "create-ticket: one ticket, prints only its number"
issue 249 spec
issue 250 ""
echo "## What to build" > "$tmp/one.md"
bash "$script" create-ticket 249 --title "하나" --body-file "$tmp/one.md" --model opus --blocked-by "#250" \
  > "$tmp/stdout" 2> "$tmp/log"
eq code 0 "$?"
eq stdout 802 "$(cat "$tmp/stdout" | tr -d '\r')"
eq "#802 labels" "model:opus" "$(labels_of 802)"
eq "#802 blockers" "250" "$(blockers_of 802)"
eq "sub-issues" "802" "$(subs_of 249)"

setup "create-ticket: a .claude/ ticket gets the claude marker"
issue 249 spec
echo "x" > "$tmp/one.md"
bash "$script" create-ticket 249 --title "훅" --body-file "$tmp/one.md" --local claude > "$tmp/stdout" 2> "$tmp/log"
eq stdout 801 "$(cat "$tmp/stdout" | tr -d '\r')"
has "marker" "<!-- factory-touches-claude -->" "$(body_of 801)"
eq "#801 labels" "local,ready-for-human" "$(labels_of 801)"

# --- workflow wiring -----------------------------------------------------------------------

current="workflow: the agent runs only in new and decomposed mode"
cond=$(awk '/- name: Decompose$/ { f = 1 } f && /if:/ { print; exit }' "$workflow")
has "agent condition" "steps.state.outputs.mode == 'new' || steps.state.outputs.mode == 'decomposed'" "$cond"
current="workflow: the agent may run create-tickets and create-ticket (#185)"
tools=$(grep -- '--allowedTools' "$workflow")
has "allowedTools" "Bash(bash .github/factory/decompose.sh create-tickets:*)" "$tools"
has "allowedTools" "Bash(bash .github/factory/decompose.sh create-ticket:*)" "$tools"
current="workflow: the ledger line of a run carries the ticket count"
has "record" 'record decompose "$SPEC" ${tickets:+"tickets=$tickets"}' "$(cat "$workflow")"
current="workflow: the old approve-and-start step is gone"
eq "approve step" 0 "$(grep -c 'Approve tickets and start the chain' "$workflow" || true)"

echo "decompose.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
