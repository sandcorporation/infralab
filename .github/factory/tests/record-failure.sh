#!/usr/bin/env bash
# Tests of .github/factory/record-failure.sh against the fake gh (tests/fake/gh), #410.
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
eq "no human marker" 0 "$(count '<!-- factory-human')"

setup "three infrastructure failures leave the factory-human marker"
fail_once infra; fail_once infra
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "human marker" 1 "$(count '<!-- factory-human attempts-exhausted -->')"

setup "two code failures go to a person"
fail_once code
bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "human marker" 1 "$(count '<!-- factory-human attempts-exhausted -->')"

setup "failures before a reset do not count"
fail_once infra; fail_once infra
say '<!-- factory-reset -->
고쳤다.'
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "no human marker" 0 "$(count '<!-- factory-human')"

setup "a blocked comment goes to a person at once without a failure"
say '<!-- factory-implementer-blocked -->
ADR-0003과 부딪힌다.'
bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "no failure marker" 0 "$(count '<!-- factory-implementer-failed -->')"
eq "human marker" 1 "$(count '<!-- factory-human agent-blocked -->')"
eq "quotes the block" true "$(jq '.[-1].body | contains("ADR-0003과 부딪힌다.")' "$FAKE_GH/comments-7.json" | tr -d '\r')"

say_at() { # say_at <time> <body>: a comment on #7 at that time
  jq --arg b "$2" --arg t "$1" '. + [{id: (length + 1), created_at: $t, body: $b, user: {login: "github-actions[bot]"}}]'     "$FAKE_GH/comments-7.json" | tr -d '' > "$FAKE_GH/c" && mv "$FAKE_GH/c" "$FAKE_GH/comments-7.json"
}

setup "no commits and a reason comment since the run started go to a person at once (#414)"
say_at 2026-11-17T00:30:00Z '이전 run의 이야기'
say_at 2026-11-17T02:10:00Z '<!-- factory-implementer-infra-failed -->
marker, not a reason'
say_at 2026-11-17T02:05:00Z '.github/workflows/ci.yml에 단계를 하나 더해야 한다.'
bash "$script" 7 infra https://example.invalid/run/1 2026-11-17T02:00:00Z > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "no new failure marker (only the one said above)" 1 "$(count '<!-- factory-implementer-infra-failed -->')"
eq "human marker" 1 "$(count '<!-- factory-human agent-blocked -->')"
eq "quotes the reason" true "$(jq '.[-1].body | contains("ci.yml에 단계를")' "$FAKE_GH/comments-7.json" | tr -d '')"
eq "not the older comment" false "$(jq '.[-1].body | contains("이전 run")' "$FAKE_GH/comments-7.json" | tr -d '')"

setup "no commits without a comment since the run started counts a failure (#414)"
say_at 2026-11-17T00:30:00Z '이전 run의 이야기'
bash "$script" 7 infra https://example.invalid/run/1 2026-11-17T02:00:00Z > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "failure marker" 1 "$(count '<!-- factory-implementer-infra-failed -->')"
eq "no human marker" 0 "$(count '<!-- factory-human')"

setup "a reason goes into the failure comment (#434)"
FAILURE_REASON='충돌을 풀지 않고 끝남: 풀리지 않은 파일이 남았다: a.rs' \
  bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "failure marker" 1 "$(count '<!-- factory-implementer-failed -->')"
eq "reason in the comment" true "$(jq '.[-1].body | contains("충돌을 풀지 않고 끝남: 풀리지 않은 파일이 남았다: a.rs")' "$FAKE_GH/comments-7.json" | tr -d '\r')"

say_by() { # say_by <login> <time> <body>: a comment on #7 by that login (type Bot when it ends in [bot])
  jq --arg u "$1" --arg t "$2" --arg b "$3" '. + [{id: (length + 1), created_at: $t, body: $b,
      user: {login: $u, type: (if ($u | endswith("[bot]")) then "Bot" else "User" end)}}]' \
    "$FAKE_GH/comments-7.json" | tr -d '\r' > "$FAKE_GH/c" && mv "$FAKE_GH/c" "$FAKE_GH/comments-7.json"
}

setup "a reason comment by a person, not a bot, is not taken as the agent's reason (#492)"
say_by someone 2026-11-17T02:05:00Z '아무나 단 댓글'
bash "$script" 7 infra https://example.invalid/run/1 2026-11-17T02:00:00Z > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "no human marker" 0 "$(count '<!-- factory-human')"

setup "a reason comment by an App bot is taken as the agent's reason (#492)"
say_by example-bot[bot] 2026-11-17T02:05:00Z '워크플로 파일을 고쳐야 한다.'
bash "$script" 7 infra https://example.invalid/run/1 2026-11-17T02:00:00Z > /dev/null 2>&1
eq labels ready-for-human "$(labels)"
eq "human marker" 1 "$(count '<!-- factory-human agent-blocked -->')"

setup "a blocked marker by a person is not a block (#492)"
say_by someone 2026-11-17T01:00:00Z '<!-- factory-implementer-blocked -->
멈춰라'
bash "$script" 7 infra https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"
eq "no human marker" 0 "$(count '<!-- factory-human')"

setup "failure markers by a person do not count (#492)"
say_by someone 2026-11-17T01:00:00Z '<!-- factory-implementer-failed -->'
bash "$script" 7 code https://example.invalid/run/1 > /dev/null 2>&1
eq labels ready-for-agent "$(labels)"

echo "record-failure.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
