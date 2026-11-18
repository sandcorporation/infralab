#!/usr/bin/env bash
# Tests of .github/factory/local-ticket.sh and the `local` rule of dispatch-next.sh (#56).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../local-ticket.sh"
dispatch="$here/../dispatch-next.sh"
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
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_TRACKS=1 FACTORY_LIST_RETRY_WAIT=0 FACTORY_DISPATCH_SEEN_WAIT=0
  mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls.log"; : > "$GITHUB_OUTPUT"
}
issue() { # issue <n> <labels csv> <title> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg t "$3" --arg b "$4" \
    '{number: $n, state: "open", title: $t, body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    > "$FAKE_GH/issue-$1.json"
}
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-$1.json"; }
res() { sed -n 's/^local=//p' "$GITHUB_OUTPUT" | tail -n 1; }
ncomments() { [ -f "$FAKE_GH/comments-$1.json" ] && jq length "$FAKE_GH/comments-$1.json" || echo 0; }

setup "a ticket that names .github/workflows becomes ready-for-human + local"
issue 80 ready-for-agent,model:sonnet "CI 단계 추가" "ci.yml 대신 .github/workflows/factory-x.yml 을 고친다"
bash "$script" 80 > /dev/null 2>&1; eq "exit" 0 $?
eq "local" true "$(res)"
eq "labels" "local,model:sonnet,ready-for-human" "$(labels 80)"
eq "one comment" 1 "$(ncomments 80)"
eq "marker" "<!-- factory-local -->" "$(jq -r '.[0].body | split("\n")[0]' "$FAKE_GH/comments-80.json")"
bash "$script" 80 > /dev/null 2>&1
eq "again: no second comment" 1 "$(ncomments 80)"
eq "again: labels the same" "local,model:sonnet,ready-for-human" "$(labels 80)"

setup "an ordinary ticket is left alone"
issue 81 ready-for-agent "백엔드" "모델을 더한다"
bash "$script" 81 > /dev/null 2>&1
eq "local" false "$(res)"
eq "labels" "ready-for-agent" "$(labels 81)"
eq "no comment" 0 "$(ncomments 81)"

setup "the title counts too, and the local label alone is enough"
issue 82 ready-for-agent ".github/workflows 정리" "x"
bash "$script" 82 > /dev/null 2>&1
eq "title" true "$(res)"
issue 83 local,ready-for-human "x" "y"
: > "$GITHUB_OUTPUT"
bash "$script" 83 > /dev/null 2>&1
eq "local label" true "$(res)"

setup "dispatch-next does not pick a local ticket"
jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}]}' > "$FAKE_GH/issue-50.json"
issue 61 ready-for-agent,local "x" "## Parent

#50"
issue 62 ready-for-agent "x" "## Parent

#50"
bash "$dispatch" --tickets-only > "$tmp/log" 2>&1
eq "only the other" 62 "$(grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//')"

echo "local-ticket.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
