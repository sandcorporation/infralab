#!/usr/bin/env bash
# .claude/hooks/block-direct-merge.py 시험(#164) — Claude Code 가 주는 PreToolUse JSON 을 흉내 내 넣는다.
#   bash .claude/hooks/block-direct-merge_test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hook="$here/block-direct-merge.py"

pass=0 fail=0
check() {  # 이름 기대코드(0 지나감 / 2 막음) 명령 [tool_name]
  local name="$1" want="$2" cmd="$3" tool="${4:-Bash}" rc=0 err
  err="$(jq -cn --arg c "$cmd" --arg t "$tool" '{tool_name: $t, tool_input: {command: $c}}' | python3 "$hook" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" = "$want" ] && { [ "$want" = 0 ] || grep -qF "scripts/pr-merge.sh <PR> 로 병합하라" <<<"$err"; }; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name: rc=$rc(want $want) err=$err"
  fi
}

check pr-merge             2 'gh pr merge 12 --squash --delete-branch'
check pr-merge-chained     2 'cd wt && git push && gh pr merge 12 --squash'
check pr-merge-after-guard 2 'scripts/pr-merge.sh 12 || gh pr merge 12 --admin'
check pr-merge-spaces      2 'gh  pr   merge 12'
check api-rest-merge       2 'gh api -X PUT repos/o/r/pulls/12/merge -f merge_method=squash'
check api-rest-quoted      2 'gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash'
check api-graphql-merge    2 "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
check via-guard            0 'scripts/pr-merge.sh 12'
check via-guard-abs        0 'bash /home/u/wt/scripts/pr-merge.sh 12 && git worktree remove x'
check git-merge            0 'git merge --no-edit origin/main'
check pr-view              0 'gh pr view 12 --json state,mergedAt,mergeCommit'
check pr-checks            0 'gh pr checks 12'
check api-pulls-get        0 'gh api repos/o/r/pulls/12'
check api-pipe-merge-word  0 'gh api repos/o/r/pulls/12 | jq .mergeable'
check other-tool           0 'gh pr merge 12' Write

# 입력이 깨져도 막지 않는다(훅 고장이 모든 Bash 를 막지 않게).
rc=0; echo 'not json' | python3 "$hook" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && { pass=$((pass + 1)); echo "ok   bad-input"; } || { fail=$((fail + 1)); echo "FAIL bad-input: rc=$rc"; }

# settings.json 이 이 훅을 Bash PreToolUse 에 건다.
settings="$here/../settings.json"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains(".claude/hooks/block-direct-merge.py"))' "$settings" >/dev/null; then
  pass=$((pass + 1)); echo "ok   settings-registered"
else
  fail=$((fail + 1)); echo "FAIL settings-registered"
fi

echo "block-direct-merge_test: $pass 통과, $fail 실패"
[ "$fail" = 0 ]
