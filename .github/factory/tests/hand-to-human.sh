#!/usr/bin/env bash
# Tests of .github/factory/hand-to-human.sh against the fake gh (tests/fake/gh), #192.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../hand-to-human.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo
root=$(mktemp -d)
trap 'rm -r "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

setup() { # setup <name> <labels comma-separated>
  current=$1
  export FAKE_GH="$root/$RANDOM$RANDOM"
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  jq -n --arg l "$2" '{number: 7, state: "open", body: "", labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-7.json"
  echo '[]' > "$FAKE_GH/comments-7.json"
}
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-7.json" | tr -d '\r'; }
comments() { jq -r '[.[].body] | join("\n---\n")' "$FAKE_GH/comments-7.json" | tr -d '\r'; }
run() { bash "$script" "$@" > "$root/log" 2>&1; echo $? > "$root/code"; }
code() { cat "$root/code"; }

setup "takes in-progress and ready-for-agent off, adds ready-for-human and leaves the marker with the reason" \
  "spec-ticket,in-progress,ready-for-agent"
run 7 "까닭 한 줄"
eq code 0 "$(code)"
eq labels "ready-for-human,spec-ticket" "$(labels)"
eq comment "<!-- factory-human -->
까닭 한 줄" "$(comments)"

setup "an issue without the factory labels gets the label and the comment" ""
run 7 "까닭"
eq code 0 "$(code)"
eq labels ready-for-human "$(labels)"
eq "one comment" 1 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"

setup "a failed comment exits 1 but the label is still put on" "in-progress"
touch "$FAKE_GH/fail-comments"
run 7 "까닭"
eq code 1 "$(code)"
eq labels ready-for-human "$(labels)"

setup "a bad issue number or a missing reason is a usage error and changes nothing" "in-progress"
run x "까닭"
eq "not a number" 2 "$(code)"
run 7
eq "no reason" 2 "$(code)"
eq labels in-progress "$(labels)"

# Only hand-to-human.sh puts ready-for-human on: a hand-over without its marker comment reaches nobody.
current="no other factory file or workflow adds ready-for-human"
github=$(cd "$here/../.." && pwd)
adders=$(grep -rnE 'ready-for-human' "$github/factory" "$github/workflows" \
  | grep -v "^$github/factory/tests/" \
  | grep -v "^$github/factory/hand-to-human.sh:" \
  | grep -v "^$github/factory/bridge.sh:" \
  | grep -E -- "--add-label[= ]+[\"']?ready-for-human|labels\[\]=[\"']?ready-for-human|add_label[^|;]*ready-for-human|addLabels?[^|;]*ready-for-human|for [a-z_]+ in [^;]*ready-for-human" || true)
eq "adders" "" "$adders"
case "$(cat "$github/factory/hand-to-human.sh")" in *'LABEL=ready-for-human'*) ok ;; *) bad "hand-to-human.sh no longer names the label" ;; esac

echo "hand-to-human.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
