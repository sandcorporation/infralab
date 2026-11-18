#!/usr/bin/env bash
# Tests of .github/factory/workflow-guard.sh (a workflow file the Implementer cannot push, #56).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../workflow-guard.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output"
  mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls.log"; : > "$GITHUB_OUTPUT"
  jq -n '{number: 70, state: "open", body: "x", labels: [{name: "in-progress"}]}' > "$FAKE_GH/issue-70.json"
  # a repository whose branch changes a file
  repo="$tmp/repo"
  git init -q "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$repo" branch -M main
  git -C "$repo" switch -q -c work
}
labels() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-70.json"; }
commit_file() { mkdir -p "$repo/$(dirname "$1")"; echo x > "$repo/$1"; git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m c; }
comment_first() { jq -r '.[0].body | split("\n")[0]' "$FAKE_GH/comments-70.json" 2>/dev/null; }

setup "a diff with .github/workflows is handed to a person"
commit_file .github/workflows/x.yml
( cd "$repo" && bash "$script" check 70 main > "$tmp/log" 2>&1 ); eq "exit" 0 $?
eq "labels" "ready-for-human" "$(labels)"
eq "marker" "<!-- factory-human -->" "$(comment_first)"
has "blocked" "blocked=true" "$(cat "$GITHUB_OUTPUT")"
eq "nothing dispatched" 0 "$(grep -c 'workflow run' "$FAKE_GH/calls.log")"
eq "no failure comment" 0 "$(jq '[.[] | select(.body | contains("factory-implementer"))] | length' "$FAKE_GH/comments-70.json")"

setup "a diff without it goes on"
commit_file backend/a.py
( cd "$repo" && bash "$script" check 70 main > "$tmp/log" 2>&1 ); eq "exit" 1 $?
eq "labels unchanged" "in-progress" "$(labels)"
has "not blocked" "blocked=false" "$(cat "$GITHUB_OUTPUT")"

setup "the push refusal is not a failure"
printf '%s\n' "! [remote rejected] agent/issue-70 -> agent/issue-70 (refusing to allow a GitHub App to create or update workflow \`.github/workflows/a.yml\` without \`workflows\` permission)" > "$tmp/push.log"
bash "$script" push-failed 70 "$tmp/push.log" > /dev/null 2>&1; eq "exit" 0 $?
eq "labels" "ready-for-human" "$(labels)"
eq "marker" "<!-- factory-human -->" "$(comment_first)"

setup "another push error stays a failure"
echo "fatal: unable to access: Could not resolve host" > "$tmp/push.log"
bash "$script" push-failed 70 "$tmp/push.log" > /dev/null 2>&1; eq "exit" 1 $?
eq "labels unchanged" "in-progress" "$(labels)"

echo "workflow-guard.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
