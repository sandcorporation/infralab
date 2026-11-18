#!/usr/bin/env bash
# Tests of .github/factory/parent-check.sh (ready-for-agent needs a parent spec, #56).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../parent-check.sh"
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

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output"
  mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls.log"; : > "$GITHUB_OUTPUT"
}
issue() { # issue <n> <labels csv> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg b "$3" \
    '{number: $n, state: "open", body: $b, labels: ($l | split(",") | map({name: .}))}' > "$FAKE_GH/issue-$1.json"
}
labels() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-$1.json"; }
ncomments() { [ -f "$FAKE_GH/comments-$1.json" ] && jq length "$FAKE_GH/comments-$1.json" || echo 0; }
res() { sed -n 's/^ok=//p' "$GITHUB_OUTPUT" | tail -n 1; }
perm() { echo "{\"permission\": \"$2\"}" > "$FAKE_GH/permission-$1.json"; }

setup "no parent: the label comes off, a comment, no start"
issue 80 ready-for-agent "손으로 만든 티켓"
perm alice write
bash "$script" 80 alice > /dev/null 2>&1; eq "exit" 0 $?
eq "ok" false "$(res)"
eq "label off" "" "$(labels 80)"
eq "one comment" 1 "$(ncomments 80)"
eq "marker" "<!-- factory-no-parent -->" "$(jq -r '.[0].body | split("\n")[0]' "$FAKE_GH/comments-80.json")"
eq "mentions the fix" 1 "$(jq '.[0].body | contains("## Parent")' "$FAKE_GH/comments-80.json" | grep -c true)"

setup "a Parent section is a parent"
issue 80 ready-for-agent "x

## Parent

#45"
perm alice write
bash "$script" 80 alice > /dev/null 2>&1
eq "ok" true "$(res)"
eq "label stays" ready-for-agent "$(labels 80)"
eq "no comment" 0 "$(ncomments 80)"

setup "a sub-issue parent is a parent"
issue 80 ready-for-agent "no section"
echo '{"number": 45}' > "$FAKE_GH/parent-80.json"
bash "$script" 80 "github-actions[bot]" > /dev/null 2>&1
eq "ok" true "$(res)"
eq "label stays" ready-for-agent "$(labels 80)"

setup "a spec is not a ticket"
issue 45 ready-for-agent,spec "spec"
bash "$script" 45 > /dev/null 2>&1
eq "ok" true "$(res)"
eq "label stays" ready-for-agent,spec "$(labels 45)"

setup "a label from someone without write permission is left alone"
issue 80 ready-for-agent "no parent"
perm mallory read
bash "$script" 80 mallory > /dev/null 2>&1
eq "ok" true "$(res)"
eq "label stays" ready-for-agent "$(labels 80)"
eq "no comment" 0 "$(ncomments 80)"

echo "parent-check.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
