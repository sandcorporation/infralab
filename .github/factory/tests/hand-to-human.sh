#!/usr/bin/env bash
# Tests of .github/factory/hand-to-human.sh against the fake gh (tests/fake/gh), #410.
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
run 7 conflict "까닭 한 줄"
eq code 0 "$(code)"
eq labels "ready-for-human,spec-ticket" "$(labels)"
eq comment "<!-- factory-human conflict -->
까닭 한 줄" "$(comments)"

setup "an issue without the factory labels gets the label and the comment" ""
run 7 other "까닭"
eq code 0 "$(code)"
eq labels ready-for-human "$(labels)"
eq "one comment" 1 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"

setup "a failed comment exits 1 but the label is still put on" "in-progress"
touch "$FAKE_GH/fail-comments"
run 7 other "까닭"
eq code 1 "$(code)"
eq labels ready-for-human "$(labels)"

setup "a bad issue number or a missing reason is a usage error and changes nothing" "in-progress"
run x other "까닭"
eq "not a number" 2 "$(code)"
run 7 other
eq "no reason" 2 "$(code)"
run 7 "까닭"
eq "no code" 2 "$(code)"
run 7 other ""
eq "empty reason" 2 "$(code)"
eq labels in-progress "$(labels)"

setup "an unknown code is a usage error and changes nothing" "in-progress"
run 7 nonsense "까닭"
eq code 2 "$(code)"
eq labels in-progress "$(labels)"
eq "no comment" 0 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"
case "$(cat "$root/log")" in *'unknown code [nonsense]'*) ok ;; *) bad "the error names the code: $(cat "$root/log")" ;; esac

for c in conflict acceptance-unpassable push-rejected attempts-exhausted agent-blocked workflow-change local-only spec-merge-failed other; do
  setup "code $c is allowed and goes into the marker" ""
  run 7 "$c" "까닭"
  eq code 0 "$(code)"
  eq marker "<!-- factory-human $c -->" "$(jq -r '.[0].body' "$FAKE_GH/comments-7.json" | tr -d '\r' | head -n 1)"
done

setup "the hand-over goes on the ledger as a handover event with its code" ""
jq -n '{number: 900, state: "open", title: "장부", body: "", labels: [{name: "factory-ledger"}]}' | tr -d '\r' > "$FAKE_GH/issue-900.json"
echo '[]' > "$FAKE_GH/comments-900.json"
GITHUB_RUN_ID=55 run 7 push-rejected "까닭"
eq code 0 "$(code)"
eq "ledger event" "<!-- factory-event -->
event=handover issue=#7 code=push-rejected run=55" "$(jq -r '[.[].body] | join("\n---\n")' "$FAKE_GH/comments-900.json" | tr -d '\r')"

setup "a deferred issue is left as it is: no label, no comment, only a warning (#437, #473)" "local,deferred"
run 7 local-only "까닭"
eq code 0 "$(code)"
eq labels "deferred,local" "$(labels)"
eq "no comment" 0 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"
case "$(cat "$root/log")" in *'::warning::'*deferred*) ok ;; *) bad "warns about deferred: $(cat "$root/log")" ;; esac

setup "an issue already handed over with the same code whose ready-for-human a person took off is not handed over again" "local"
jq -n '[{id: 1, created_at: "2026-11-17T00:00:00Z", body: "<!-- factory-human local-only -->\n<!-- factory-local -->\n까닭", user: {login: "github-actions[bot]"}}]' \
  | tr -d '\r' > "$FAKE_GH/comments-7.json"
run 7 local-only "까닭"
eq code 0 "$(code)"
eq labels local "$(labels)"
eq "still one comment" 1 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"
case "$(cat "$root/log")" in *'::warning::'*'already handed over'*) ok ;; *) bad "warns about the earlier hand-over: $(cat "$root/log")" ;; esac

setup "a different code, or an issue put back in the factory, is handed over again" "ready-for-agent"
jq -n '[{id: 1, created_at: "2026-11-17T00:00:00Z", body: "<!-- factory-human attempts-exhausted -->\n까닭", user: {login: "github-actions[bot]"}}]' \
  | tr -d '\r' > "$FAKE_GH/comments-7.json"
run 7 attempts-exhausted "까닭"
eq "back in the factory" ready-for-human "$(labels)"
run 7 conflict "다른 까닭"
eq "other code" 3 "$(jq length "$FAKE_GH/comments-7.json" | tr -d '\r')"

setup "no ledger issue is not a failure" ""
run 7 other "까닭"
eq code 0 "$(code)"

# Only hand-to-human.sh puts ready-for-human on: a hand-over without its marker comment reaches nobody.
current="no other factory file or workflow adds ready-for-human"
github=$(cd "$here/../.." && pwd)
adders=$(grep -rnE 'ready-for-human' "$github/factory" "$github/workflows" \
  | grep -v "^$github/factory/tests/" \
  | grep -v "^$github/factory/hand-to-human.sh:" \
  | grep -E -- "--add-label[= ]+[\"']?ready-for-human|labels\[\]=[\"']?ready-for-human|add_label[^|;]*ready-for-human|addLabels?[^|;]*ready-for-human" || true)
eq "adders" "" "$adders"
case "$(cat "$github/factory/hand-to-human.sh")" in *'LABEL=ready-for-human'*) ok ;; *) bad "hand-to-human.sh no longer names the label" ;; esac

setup "the reason comment goes on before the label, so whoever sees the label finds the reason (#492)" "in-progress"
run 7 agent-blocked "까닭"
order=$(grep -nE 'issues/7/(comments|labels) ' "$FAKE_GH/calls.log" | grep -v DELETE | sed -E 's/^([0-9]+):.*issues\/7\/(comments|labels).*/\2/' | tr '\n' ' ')
eq "comment then label" "comments labels " "$order"

echo "hand-to-human.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
