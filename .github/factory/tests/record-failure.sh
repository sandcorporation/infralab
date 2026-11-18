#!/usr/bin/env bash
# Tests of .github/factory/record-failure.sh against the fake gh (tests/fake/gh), #192.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../record-failure.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo
root=$(mktemp -d)
trap 'rm -r "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

setup() {
  current=$1
  export FAKE_GH="$root/$RANDOM$RANDOM"
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  jq -n '{number: 7, state: "open", body: "", labels: [{name: "in-progress"}]}' | tr -d '\r' > "$FAKE_GH/issue-7.json"
  echo '[]' > "$FAKE_GH/comments-7.json"
}
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-7.json" | tr -d '\r'; }
count() { jq --arg m "$1" '[.[] | select(.body | startswith($m))] | length' "$FAKE_GH/comments-7.json" | tr -d '\r'; }
say() { # say <body>: a comment on #7
  jq --arg b "$1" '. + [{id: (length + 1), created_at: "2026-11-17T01:00:00Z", body: $b, user: {login: "github-actions[bot]"}}]' \
    "$FAKE_GH/comments-7.json" | tr -d '\r' > "$FAKE_GH/c" && mv "$FAKE_GH/c" "$FAKE_GH/comments-7.json"
}
fail_once() { # fail_once <code|infra>
  bash "$script" 7 "$1" https://example.invalid/run/1 > /dev/null 2>&1
  jq '.labels |= map(select(.name != "ready-for-agent")) + [{name: "in-progress"}]' "$FAKE_GH/issue-7.json" \
    | tr -d '\r' > "$FAKE_GH/i" && mv "$FAKE_GH/i" "$FAKE_GH/issue-7.json"
}

setup "one infrastructure failure goes back to the queue"
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "failure marker" 1 "$(count '<!-- factory-implementer-infra-failed -->')"
eq "no human marker" 0 "$(count '<!-- factory-human -->')"

setup "three infrastructure failures leave the factory-human marker"
fail_once infra; fail_once infra
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "human marker" 1 "$(count '<!-- factory-human -->')"

setup "two code failures go to a person"
fail_once code
bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "human marker" 1 "$(count '<!-- factory-human -->')"

setup "failures before a reset do not count"
fail_once infra; fail_once infra
say '<!-- factory-reset -->
고쳤다.'
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "no human marker" 0 "$(count '<!-- factory-human -->')"

setup "a blocked comment goes to a person at once without a failure"
say '<!-- factory-implementer-blocked -->
ADR-0003과 부딪힌다.'
bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "no failure marker" 0 "$(count '<!-- factory-implementer-failed -->')"
eq "human marker" 1 "$(count '<!-- factory-human -->')"
eq "quotes the block" true "$(jq '.[-1].body | contains("ADR-0003과 부딪힌다.")' "$FAKE_GH/comments-7.json" | tr -d '\r')"

echo "record-failure.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
