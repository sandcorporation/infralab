#!/usr/bin/env bash
# Finishes the merge the Implementer's conflict agent left, and checks that main really landed on the
# branch before the run pushes it (#434).
#
#   merge-check.sh finish
#   merge-check.sh check <main commit>
#
# finish (factory-implementer.yml, "Finish merge", after "Resolve conflicts"): when a merge is in
# progress (MERGE_HEAD), no path may be left unmerged and no conflict marker (`<<<<<<< `, `>>>>>>> `,
# `=======` alone on a line) may be among the lines the merge adds; then the script stages the whole
# working tree and makes the merge commit itself. Runs 44389000388 and 44393130003 (#342): the agent
# resolved the conflicts and ended without `git commit --no-edit`, so HEAD stayed the PR's old head.
# Without a merge in progress it does nothing.
#
# check ("Require main merged"): the branch is fine when no merge or rebase is still in progress, no
# file is left unmerged, and HEAD contains <main commit> (the main the rebase step fetched: a later
# fetch by the agent must not move the target). Otherwise the run is recorded as an Implementer
# failure instead of going to Verify, which sent the PR's old head back for the same conflict until
# the limit ran out.
#
# Both print the reason on failure (`::error::`, and `reason=` in GITHUB_OUTPUT for Record failure's
# comment) and exit 1.
set -u
usage() { echo 'usage: merge-check.sh finish | merge-check.sh check <main commit>' >&2; exit 2; }

unmerged() { git diff --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ $//'; }

# marked_files <commit>: files whose staged lines added against <commit> include a conflict marker.
marked_files() {
  git diff --cached --no-color --no-ext-diff -U0 "$1" \
    | awk '/^\+\+\+ / { f = substr($0, 7); next }
           /^\+(<<<<<<< |>>>>>>> |=======$)/ { if (!(f in seen)) { seen[f] = 1; print f } }' | sort
}

# finish_merge: commits a resolved merge; prints why it cannot, or nothing; returns 1 or 0.
finish_merge() {
  git rev-parse -q --verify MERGE_HEAD > /dev/null || return 0
  local left markers
  left=$(unmerged)
  if [ -n "$left" ]; then
    echo "충돌을 풀지 않고 끝남: 풀리지 않은 파일이 남았다: $left"
    return 1
  fi
  git add -A || { echo "충돌을 풀지 않고 끝남: 작업 트리를 올리지 못했다"; return 1; }
  # A marker counts when neither side had it: main's own `=======` lines (a heading underline, say)
  # show up as added against HEAD only.
  markers=$(comm -12 <(marked_files HEAD) <(marked_files MERGE_HEAD) | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$markers" ]; then
    echo "충돌을 풀지 않고 끝남: 충돌 표지가 남았다: $markers"
    return 1
  fi
  git commit -q --no-edit || { echo "충돌을 풀지 않고 끝남: merge 커밋을 만들지 못했다"; return 1; }
}

# merge_check <main commit>: prints why main is not on the branch, or nothing; returns 1 or 0.
merge_check() {
  local gitdir left
  gitdir=$(git rev-parse --git-dir) || { echo "not a git repository"; return 1; }
  if git rev-parse -q --verify MERGE_HEAD > /dev/null; then
    left=$(unmerged)
    echo "충돌을 풀지 않고 끝남: merge가 끝나지 않았다(MERGE_HEAD 남음; 풀리지 않은 파일: ${left:-없음})"
    return 1
  fi
  if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
    echo "충돌을 풀지 않고 끝남: rebase가 끝나지 않았다"
    return 1
  fi
  left=$(unmerged)
  if [ -n "$left" ]; then
    echo "충돌을 풀지 않고 끝남: 풀리지 않은 파일이 남았다: $left"
    return 1
  fi
  if ! git merge-base --is-ancestor "$1" HEAD; then
    echo "충돌을 풀지 않고 끝남: 브랜치(HEAD $(git rev-parse --short HEAD))에 main($(git rev-parse --short "$1"))이 들어가지 않았다"
    return 1
  fi
}

case "${1:-}" in
  finish) [ $# -eq 1 ] || usage
    if reason=$(finish_merge); then
      echo "merge finished or none in progress (HEAD $(git rev-parse --short HEAD))"
      exit 0
    fi ;;
  check) [ $# -eq 2 ] || usage
    if reason=$(merge_check "$2"); then
      echo "main $(git rev-parse --short "$2") is on the branch"
      exit 0
    fi ;;
  *) usage ;;
esac
echo "::error::$reason"
[ -n "${GITHUB_OUTPUT:-}" ] && printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
exit 1
