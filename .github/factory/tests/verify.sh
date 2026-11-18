#!/usr/bin/env bash
# Tests of .github/factory/verify.sh: `mech` against throwaway git repositories, `sendback` and
# `pass` against the fake gh (tests/fake/gh).
set -u
here=$(cd "$(dirname "$0")" && pwd)
verify="$here/../verify.sh"
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

# --- mech: a repository whose main has the acceptance tests of tickets #7, #8 and #70 ----------
# (conventions of spec-tests.sh: backend pytest, web vitest, agent go)

PY=backend/tests/test_spec_demo_api.py
WEB=web/src/spec/spec_demo_page.test.ts
GO=agent/spec_demo_check_test.go

py_file() {
  cat <<'EOF'
import pytest

from app import seven, eight, seventy


@pytest.mark.skip(reason="#7")
def test_seven_does_it():
    assert seven() == 7


@pytest.mark.skip(reason="#8")
def test_eight_does_it():
    assert eight() == 8


@pytest.mark.skip(reason="#70")
def test_seventy_does_it():
    assert seventy() == 70
EOF
}

web_file() {
  cat <<'EOF'
import { expect, it } from "vitest";
import { seven, eight } from "../app";

it.skip("seven shows 7", () => { // #7
  expect(seven()).toBe(7);
});

test.skip("eight shows 8", () => { // #8
  expect(eight()).toBe(8);
});
EOF
}

go_file() {
  cat <<'EOF'
package main

import "testing"

func TestSevenDoesIt(t *testing.T) {
	t.Skip("#7")
	if seven() != 7 {
		t.Fatal("seven")
	}
}

func TestEightDoesIt(t *testing.T) {
	t.Skip("#8")
	if eight() != 8 {
		t.Fatal("eight")
	}
}
EOF
}

# repo <name>: a new repository with main = the spec files and a source file, on branch "ticket"
repo() {
  current=$1
  r="$root/$1"
  mkdir -p "$r/backend/tests" "$r/backend/app" "$r/web/src/spec" "$r/agent"
  cd "$r" || exit 1
  git init -q -b main .
  git config core.autocrlf false
  git config user.name test
  git config user.email test@example.invalid
  py_file > "$PY"
  web_file > "$WEB"
  go_file > "$GO"
  printf 'def seven():\n    return 0\n' > backend/app/__init__.py
  git add -A && git commit -q -m base
  git switch -q -c ticket
}

commit() { git add -A && git commit -q -m change; }

# on7: switch every acceptance test of #7 on, as the Implementer does
on7() {
  sed -i '/@pytest.mark.skip(reason="#7")/d' "$PY"
  sed -i 's|^it\.skip(\(.*\)) => { // #7$|it(\1) => {|' "$WEB"
  sed -i '/t.Skip("#7")/d' "$GO"
}

# mech_run: runs `verify.sh mech 7 main`; sets $status and $report
mech_run() {
  report=$(bash "$verify" mech 7 main 2>&1)
  status=$?
}

repo only-switched-on
on7
printf 'def seven():\n    return 7\n' > backend/app/__init__.py
commit
mech_run
eq "exit" 0 "$status"
has "report" "기계 검사 통과" "$report"
eq "web line" 'it("seven shows 7", () => {' "$(sed -n 4p "$WEB")"

repo py-marker-left
on7
git checkout -q main -- "$PY"
commit
mech_run
eq "exit" 1 "$status"
has "report" '꺼진 채 남아 있다' "$report"
has "report names the file" "$PY" "$report"
lacks "#70 is another ticket" 'reason="#70"' "$report"

repo go-marker-left-elsewhere
on7
printf 'package main\n\nimport "testing"\n\nfunc TestExtra(t *testing.T) {\n\tt.Skip("#7")\n}\n' > agent/other_test.go
commit
mech_run
eq "exit" 1 "$status"
has "report" "agent/other_test.go" "$report"

repo web-marker-left
on7
git checkout -q main -- "$WEB"
commit
mech_run
eq "exit" 1 "$status"
has "report" 'web 인수 시험이 꺼진 채' "$report"
has "report names the file" "$WEB:4" "$report"

# Odin's stubs of the contract must be gone; another ticket's stub may stay.
repo stub-left
on7
printf 'def seven():\n    raise NotImplementedError("#7")\n\n\ndef seventy():\n    raise NotImplementedError("#70")\n' > backend/app/__init__.py
printf 'export function seven(): number {\n  throw new Error("#7");\n}\n' > web/src/app.ts
printf 'package main\n\nfunc seven() int {\n\tpanic("#7")\n}\n' > agent/seven.go
commit
mech_run
eq "exit" 1 "$status"
has "report" '스텁이 남아 있다' "$report"
has "py stub" "backend/app/__init__.py:2" "$report"
has "ts stub" "web/src/app.ts:2" "$report"
has "go stub" "agent/seven.go:4" "$report"
lacks "another ticket's stub" '#70' "$report"

repo stub-replaced
on7
printf 'def seven():\n    return 7\n\n\ndef eight():\n    raise NotImplementedError("#8")\n' > backend/app/__init__.py
commit
mech_run
eq "exit" 0 "$status"
has "report" '기계 검사 통과' "$report"

repo assertion-changed
on7
sed -i 's/assert seven() == 7/assert seven() == 0/' "$PY"
commit
mech_run
eq "exit" 1 "$status"
has "report" "인수 시험을 고쳤다(줄을 더함)" "$report"
has "report" "assert seven() == 0" "$report"

repo web-line-changed-beyond-skip
sed -i 's|^it\.skip("seven shows 7", () => { // #7$|it("seven shows something", () => {|' "$WEB"
sed -i '/@pytest.mark.skip(reason="#7")/d' "$PY"
sed -i '/t.Skip("#7")/d' "$GO"
commit
mech_run
eq "exit" 1 "$status"
has "report" 'it("seven shows something"' "$report"
has "report" "인수 시험을 지웠다" "$report"

repo web-test-deleted
on7
git checkout -q main -- "$WEB"
sed -i '4,6d' "$WEB"
commit
mech_run
eq "exit" 1 "$status"
has "report" "인수 시험을 고쳤다(줄을 지움)" "$report"
has "report" "expect(seven()).toBe(7);" "$report"

repo test-deleted
on7
py_file | sed '/reason="#7"/,/assert seven/d' > "$PY"
commit
mech_run
eq "exit" 1 "$status"
has "report" "인수 시험을 고쳤다(줄을 지움)" "$report"
has "report" "def test_seven_does_it():" "$report"

repo other-ticket-marker
on7
sed -i '/@pytest.mark.skip(reason="#8")/d' "$PY"
sed -i 's|^test\.skip(\(.*\)) => { // #8$|test(\1) => {|' "$WEB"
sed -i '/t.Skip("#8")/d' "$GO"
commit
mech_run
eq "exit" 1 "$status"
has "report" '다른 티켓의 인수 시험을 켰다' "$report"
has "py" '@pytest.mark.skip(reason="#8")' "$report"
has "go" 't.Skip("#8")' "$report"
has "web" 'test.skip("eight shows 8", () => { // #8' "$report"

repo line-added
on7
printf '\n\ndef test_mine():\n    pass\n' >> "$PY"
commit
mech_run
eq "exit" 1 "$status"
has "report" "def test_mine():" "$report"

repo new-spec-file
on7
printf 'package main\n\nimport "testing"\n\nfunc TestMine(t *testing.T) {}\n' > agent/spec_demo_more_test.go
commit
mech_run
eq "exit" 1 "$status"
has "report" "spec_demo_more_test.go" "$report"

# main moved on after the branch started (another spec PR changed the file): only the branch's
# own change counts.
repo main-moved
on7
commit
git switch -q main
printf '\n\n@pytest.mark.skip(reason="#9")\ndef test_nine():\n    pass\n' >> "$PY"
commit
git switch -q ticket
mech_run
eq "exit" 0 "$status"

repo crlf-checkout
on7
commit
sed -i 's/$/\r/' "$PY" # a working tree with CRLF does not matter: mech reads HEAD
mech_run
eq "exit" 0 "$status"

cd "$root" || exit 1

# --- sendback and pass against the fake gh -----------------------------------------------------

setup() {
  current=$1
  tmp=$(mktemp -d "$root/g.XXXXXX")
  export FAKE_GH="$tmp/gh" FACTORY_MERGE_WAIT=0 RUN_URL=https://example.invalid/run/1
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  printf '#!/usr/bin/env bash
touch "%s/next-dispatched"; printf "%%s\n" "$*" >> "%s/next-args"
' "$tmp" "$tmp" > "$tmp/next.sh"
  export FACTORY_DISPATCH_NEXT="bash $tmp/next.sh"
  issue 7 in-progress
  jq -n '{number: 40, state: "open", merged: false, head: {ref: "agent/issue-7"}}' | tr -d '\r' > "$FAKE_GH/pull-40.json"
  printf 'AC-1: 미충족 — 시험이 없다\n' > "$tmp/reason.md"
}

issue() { # issue <n> <labels comma-separated>
  jq -n --argjson n "$1" --arg l "$2" \
    '{number: $n, state: "open", body: "", labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}
labels_of() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
state_of() { jq -r .state "$FAKE_GH/$1.json" | tr -d '\r'; }
count_marker() { # count_marker <n> <marker>
  local f="$FAKE_GH/comments-$1.json"
  [ -f "$f" ] || { echo 0; return; }
  jq --arg m "$2" '[.[] | select(.body | contains($m))] | length' "$f" | tr -d '\r'
}
calls() { cat "$FAKE_GH/calls.log"; }
next_dispatched() { [ -e "$tmp/next-dispatched" ] && echo yes || echo no; }

runs_left() { jq -r '[.[].id] | join(",")' "$FAKE_GH/runs.json" | tr -d '
'; }

setup first-sendback
jq -n '[{id: 1, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 0}]' | tr -d '
' > "$FAKE_GH/runs.json"
bash "$verify" sendback 7 40 "$tmp/reason.md" > /dev/null
eq "exit" 0 "$?"
eq "sendback comments" 1 "$(count_marker 7 '<!-- factory-sendback')"
has "the reason is in the comment" "AC-1: 미충족" "$(jq -r '.[0].body' "$FAKE_GH/comments-7.json")"
eq "PR state" closed "$(state_of pull-40)"
has "branch deleted" "git/refs/heads/agent/issue-7" "$(calls)"
eq "bot pull_request run deleted (#270)" "" "$(runs_left)"
eq "labels" ready-for-agent "$(labels_of 7)"
eq "the ticket goes first into a track (#286)" "--first 7" "$(cat "$tmp/next-args")"
lacks "no direct dispatch" "factory-implementer.yml" "$(calls)"
eq "no human marker" 0 "$(count_marker 7 '<!-- factory-human -->')"

setup second-sendback
jq -n '[{id: 1, created_at: "2026-11-17T01:00:00Z", body: "<!-- factory-sendback -->\nVerify가 PR #39을 되돌렸다.\n\n앞 사유"}]' \
  | tr -d '\r' > "$FAKE_GH/comments-7.json"
bash "$verify" sendback 7 40 "$tmp/reason.md" > /dev/null
eq "exit" 0 "$?"
eq "sendback comments" 2 "$(count_marker 7 '<!-- factory-sendback')"
eq "human marker" 1 "$(count_marker 7 '<!-- factory-human -->')"
eq "labels" ready-for-human "$(labels_of 7)"
lacks "implementer not dispatched" "factory-implementer.yml" "$(calls)"
eq "next ticket" yes "$(next_dispatched)"
eq "PR state" closed "$(state_of pull-40)"

# Other markers (implementer failures) do not count as send-backs.
setup failures-are-not-sendbacks
jq -n '[{id: 1, created_at: "2026-11-17T01:00:00Z", body: "<!-- factory-implementer-failed -->\nfailed"}]' \
  | tr -d '\r' > "$FAKE_GH/comments-7.json"
bash "$verify" sendback 7 40 "$tmp/reason.md" > /dev/null
eq "labels" ready-for-agent "$(labels_of 7)"
eq "the ticket goes first" "--first 7" "$(cat "$tmp/next-args")"

# --- send-back kinds and limits (#307) ---------------------------------------------------------

# prior <kind>...: earlier send-back comments on #7, one per kind (`old` = unmarked, before #307)
prior() {
  local i=0 k
  for k in "$@"; do
    i=$((i + 1))
    if [ "$k" = old ]; then
      printf '<!-- factory-sendback -->\nVerify가 PR #3%s을 되돌렸다.\n' "$i"
    else
      printf '<!-- factory-sendback kind=%s pr=3%s -->\nVerify가 PR #3%s을 되돌렸다.\n' "$k" "$i" "$i"
    fi | jq -Rs --argjson i "$i" '{id: $i, created_at: "2026-11-17T01:00:00Z", body: .}'
  done | jq -s . | tr -d '\r' > "$FAKE_GH/comments-7.json"
}
last_body() { jq -r '.[-1].body' "$FAKE_GH/comments-7.json" | tr -d '\r'; }
checked_pr() { # the PR body as Verify left it
  jq -n '{number: 40, state: "open", merged: false, head: {ref: "agent/issue-7"},
    body: "본문\n\nCloses #7\n\n<!-- factory-checked abc123 -->"}' | tr -d '\r' > "$FAKE_GH/pull-40.json"
}

setup conflict-sendback-keeps-the-pr
checked_pr
bash "$verify" sendback 7 40 "$tmp/reason.md" conflict > /dev/null
eq "exit" 0 "$?"
has "kind in the marker" "<!-- factory-sendback kind=conflict pr=40 -->" "$(jq -r '.[0].body' "$FAKE_GH/comments-7.json")"
eq "PR stays open" open "$(state_of pull-40)"
lacks "branch kept" "git/refs/heads/agent/issue-7" "$(calls)"
lacks "checked marker gone" "<!-- factory-checked " "$(jq -r .body "$FAKE_GH/pull-40.json")"
has "body kept" "Closes #7" "$(jq -r .body "$FAKE_GH/pull-40.json")"
eq "labels" ready-for-agent "$(labels_of 7)"
eq "the ticket goes first" "--first 7" "$(cat "$tmp/next-args")"
eq "conflict-pr reuses the PR" 40 "$(bash "$verify" conflict-pr 7 | tr -d '\r')"

setup conflict-pr-only-after-a-conflict
bash "$verify" sendback 7 40 "$tmp/reason.md" > /dev/null
has "acceptance by default" "<!-- factory-sendback kind=acceptance pr=40 -->" "$(jq -r '.[0].body' "$FAKE_GH/comments-7.json")"
eq "no conflict-pr after an acceptance failure" "" "$(bash "$verify" conflict-pr 7 | tr -d '\r')"

setup conflict-pr-closed
prior conflict
jq -n '{number: 31, state: "closed", merged: false, head: {ref: "agent/issue-7"}}' | tr -d '\r' > "$FAKE_GH/pull-31.json"
eq "no conflict-pr when its PR is closed" "" "$(bash "$verify" conflict-pr 7 | tr -d '\r')"
bash "$verify" conflict-pr 7 > /dev/null; eq "conflict-pr exits 0 (the guard runs under bash -e)" 0 "$?"

setup two-conflicts-stay-with-the-factory
prior conflict
bash "$verify" sendback 7 40 "$tmp/reason.md" conflict > /dev/null
eq "labels" ready-for-agent "$(labels_of 7)"
eq "no human marker" 0 "$(count_marker 7 '<!-- factory-human -->')"

setup three-conflicts-go-to-a-human
prior conflict acceptance conflict
bash "$verify" sendback 7 40 "$tmp/reason.md" conflict > /dev/null
eq "labels" ready-for-human "$(labels_of 7)"
eq "human marker" 1 "$(count_marker 7 '<!-- factory-human -->')"
has "names the conflict limit" "사람 넘김 한도: main과의 충돌 3번" "$(last_body)"
eq "PR stays open" open "$(state_of pull-40)"

setup two-acceptance-failures-go-to-a-human
prior conflict conflict acceptance
bash "$verify" sendback 7 40 "$tmp/reason.md" acceptance > /dev/null
eq "labels" ready-for-human "$(labels_of 7)"
has "names the acceptance limit" "사람 넘김 한도: 인수 실패 2번" "$(last_body)"

setup old-unmarked-count-as-acceptance
prior old
bash "$verify" sendback 7 40 "$tmp/reason.md" conflict > /dev/null
eq "an old one and a conflict" ready-for-agent "$(labels_of 7)"
setup old-unmarked-count-as-acceptance-2
prior old
bash "$verify" sendback 7 40 "$tmp/reason.md" acceptance > /dev/null
eq "an old one and an acceptance failure" ready-for-human "$(labels_of 7)"

setup pass
jq -n '[{id: 1, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 0}]' | tr -d '
' > "$FAKE_GH/runs.json"
printf 'AC-1: 충족 — spec_demo_a::seven_does_it\n' > "$tmp/report.md"
issue 40 ""
bash "$verify" pass 7 40 "$tmp/report.md" > /dev/null
eq "exit" 0 "$?"
eq "merged" true "$(jq -r .merged "$FAKE_GH/pull-40.json" | tr -d '\r')"
has "squash" "pulls/40/merge -f merge_method=squash" "$(calls)"
has "branch deleted" "git/refs/heads/agent/issue-7" "$(calls)"
eq "bot pull_request run deleted (#270)" "" "$(runs_left)"
eq "ticket closed" closed "$(state_of issue-7)"
eq "labels" "" "$(labels_of 7)"
has "ci dispatched" "actions/workflows/ci.yml/dispatches -f ref=main" "$(calls)"
lacks "no release workflow" "release.yml" "$(calls)"
eq "next ticket" yes "$(next_dispatched)"
has "report on the PR" "AC-1: 충족" "$(jq -r '.[0].body' "$FAKE_GH/comments-40.json")"

setup merge-fails
touch "$FAKE_GH/fail-merge"
bash "$verify" pass 7 40 > /dev/null 2>&1
eq "exit" 1 "$?"
eq "ticket open" open "$(state_of issue-7)"
eq "next ticket" no "$(next_dispatched)"
lacks "no build" "ci.yml" "$(calls)"

# --- next-verify (#286) ------------------------------------------------------------------------

# waiting <pr> <ticket> [checked]: an open PR of the Implementer for the ticket
waiting() {
  local f="$FAKE_GH/pulls.json" b="Closes #$2"
  [ "${3:-yes}" = yes ] && b="$b

<!-- factory-checked abc123 -->"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson p "$1" --arg b "$b" '. + [{number: $p, state: "open", body: $b}]' "$f" | tr -d '\r' > "$f.new" \
    && mv "$f.new" "$f"
}
verifying() { # verifying <ticket> <pr> [status]: a Verify run, not completed
  local f="$FAKE_GH/runs-list.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg t "verify #$1 (PR #$2)" --arg s "${3:-in_progress}" \
    '[{databaseId: (([.[].databaseId] | max // 1000) + 1), workflow: "factory-verify.yml", status: $s,
       event: "workflow_dispatch", displayTitle: $t}] + .' "$f" | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}
verify_dispatched() { grep '^workflow run factory-verify.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }

setup next-verify-oldest-waiting
issue 8 in-progress; issue 9 in-progress
waiting 45 9; waiting 41 8
bash "$verify" next-verify 40 > /dev/null
eq "exit" 0 "$?"
eq "the oldest PR" "8 -f pr=41" "$(verify_dispatched)"

setup next-verify-skips
issue 8 in-progress; issue 9 ready-for-agent; issue 10 in-progress
waiting 40 7; waiting 41 8 no; waiting 42 9; waiting 43 10
jq '.state = "closed"' "$FAKE_GH/issue-10.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-10.json"
bash "$verify" next-verify 40 > /dev/null
eq "this run's PR, unchecked, not in progress, closed ticket: none" "" "$(verify_dispatched)"

setup next-verify-another-run-going
waiting 41 7
verifying 9 45
bash "$verify" next-verify 40 > "$tmp/out"
eq "nothing while another Verify runs" "" "$(verify_dispatched)"
has "says so" "other Verify run" "$(cat "$tmp/out")"

setup next-verify-own-run-and-completed-runs-do-not-count
waiting 41 7
verifying 9 45 completed; verifying 7 40
GITHUB_RUN_ID=$(jq '.[0].databaseId' "$FAKE_GH/runs-list.json" | tr -d '\r') bash "$verify" next-verify 40 > /dev/null
eq "dispatched" "7 -f pr=41" "$(verify_dispatched)"

setup usage
bash "$verify" sendback 7 > /dev/null 2>&1
eq "usage exit" 2 "$?"

echo "verify.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
