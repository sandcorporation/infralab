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

# say_by <login> <created_at> <body>: a comment on #7 by <login> at <created_at>
say_by() {
  jq --arg u "$1" --arg t "$2" --arg b "$3" '. + [{id: (length + 1), created_at: $t, body: $b, user: {login: $u}}]' \
    "$FAKE_GH/comments-7.json" | tr -d '\r' > "$FAKE_GH/c" && mv "$FAKE_GH/c" "$FAKE_GH/comments-7.json"
}
STOPPED='Implementer 가 멈췄습니다(커밋 없음). 인수 시험 test_only_the_e2e_compose_turns_the_hooks_on 이 통과할 수 없습니다: ConstructorError.'

setup "#194: a run that made no commit and said why goes to a person at once (#212)"
say_by 'github-actions[bot]' 2026-11-17T02:10:00Z "$STOPPED"
RUN_STARTED_AT=2026-11-17T02:00:00Z bash "$script" 7 nocommit https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "no failure marker" 0 "$(count '<!-- factory-implementer-infra-failed -->')"
eq "human marker" 1 "$(count '<!-- factory-human -->')"
eq "quotes the reason" true "$(jq --arg s "$STOPPED" '.[-1].body | contains($s)' "$FAKE_GH/comments-7.json" | tr -d '\r')"

setup "a comment from before the run does not count as this run's (#212)"
say_by 'github-actions[bot]' 2026-11-17T01:59:59Z "$STOPPED"
RUN_STARTED_AT=2026-11-17T02:00:00Z bash "$script" 7 nocommit https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "infra failure" 1 "$(count '<!-- factory-implementer-infra-failed -->')"

setup "a person's comment or a factory marker during the run is no reason to stop (#212)"
say_by farrar142 2026-11-17T02:10:00Z '진행 상황 어때요?'
say_by 'github-actions[bot]' 2026-11-17T02:11:00Z '<!-- factory-model opus -->
model'
RUN_STARTED_AT=2026-11-17T02:00:00Z bash "$script" 7 nocommit https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "infra failure" 1 "$(count '<!-- factory-implementer-infra-failed -->')"
eq "no human marker" 0 "$(count '<!-- factory-human -->')"

setup "nocommit without RUN_STARTED_AT is an infrastructure failure (an older workflow run)"
say_by 'github-actions[bot]' 2026-11-17T02:10:00Z "$STOPPED"
RUN_STARTED_AT= bash "$script" 7 nocommit https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "infra failure" 1 "$(count '<!-- factory-implementer-infra-failed -->')"

setup "an infra failure with a comment is still counted: only nocommit reads it"
say_by 'github-actions[bot]' 2026-11-17T02:10:00Z "$STOPPED"
RUN_STARTED_AT=2026-11-17T02:00:00Z bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "infra failure" 1 "$(count '<!-- factory-implementer-infra-failed -->')"

current="factory-implementer.yml passes nocommit and the run's start (#212)"
wf=$(cat "$here/../../workflows/factory-implementer.yml")
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in the workflow" ;; esac; }
has "start time" 'echo "RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_ENV"' "$wf"
has "step id" '      - name: Require commits
        id: commits' "$wf"
has kind 'elif [ "${{ steps.commits.outcome }}" = failure ]; then what=nocommit' "$wf"

echo "record-failure.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
