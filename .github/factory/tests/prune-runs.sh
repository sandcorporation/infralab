#!/usr/bin/env bash
# Tests of .github/factory/prune-runs.sh (#270) against the fake gh (tests/fake/gh).
set -u
here=$(cd "$(dirname "$0")" && pwd)
prune="$here/../prune-runs.sh"
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

# setup <name>: the runs of ci.yml
#   1  agent/issue-7, pull_request, github-actions[bot], no job       -> deleted
#   2  agent/issue-7, pull_request, github-actions[bot], no job       -> deleted
#   3  agent/issue-7, pull_request, a person, no job                  -> kept (a person's PR)
#   4  agent/issue-7, pull_request, github-actions[bot], one job      -> kept (it ran)
#   5  agent/issue-7, workflow_dispatch, github-actions[bot], no job  -> kept (not a PR run)
#   6  agent/issue-8, pull_request, github-actions[bot], no job       -> kept (another branch)
setup() {
  current=$1
  tmp=$(mktemp -d "$root/p.XXXXXX")
  export FAKE_GH="$tmp/gh"
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  jq -n '[
    {id: 1, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 0},
    {id: 2, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 0},
    {id: 3, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "someone"}, jobs: 0},
    {id: 4, event: "pull_request", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 1},
    {id: 5, event: "workflow_dispatch", head_branch: "agent/issue-7", triggering_actor: {login: "github-actions[bot]"}, jobs: 0},
    {id: 6, event: "pull_request", head_branch: "agent/issue-8", triggering_actor: {login: "github-actions[bot]"}, jobs: 0}
  ]' | tr -d '\r' > "$FAKE_GH/runs.json"
}
ids() { jq -r '[.[].id] | join(",")' "$FAKE_GH/runs.json" | tr -d '\r'; }
cancelled() { jq -r '[.[] | select(.cancelled) | .id] | join(",")' "$FAKE_GH/runs.json" | tr -d '\r'; }

setup deletes-job-less-bot-runs
out=$(bash "$prune" agent/issue-7 2>&1)
eq "exit" 0 "$?"
eq "runs left" "3,4,5,6" "$(ids)"
eq "says how many" "pruned 2 ci.yml pull_request run(s) of agent/issue-7" "$(printf '%s' "$out" | tail -n 1)"

setup cancels-when-delete-fails
touch "$FAKE_GH/fail-delete-run"
bash "$prune" agent/issue-7 > /dev/null 2>&1
eq "exit" 0 "$?"
eq "nothing deleted" "1,2,3,4,5,6" "$(ids)"
eq "cancelled instead" "1,2" "$(cancelled)"

setup never-fails
touch "$FAKE_GH/fail-delete-run" "$FAKE_GH/fail-cancel-run"
bash "$prune" agent/issue-7 > /dev/null 2>&1
eq "exit when nothing works" 0 "$?"

setup no-runs
echo '[]' > "$FAKE_GH/runs.json"
bash "$prune" factory/spec-50 > /dev/null 2>&1
eq "exit without runs" 0 "$?"

setup usage
bash "$prune" > /dev/null 2>&1
eq "usage exit" 1 "$?"

echo "prune-runs.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
