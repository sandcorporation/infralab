#!/usr/bin/env bash
# Tests of .github/factory/merge-check.sh (main must be on the branch before the push, #434)
# against throwaway git repositories.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../merge-check.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
root=$(mktemp -d)
trap 'rm -r "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }

# setup <name>: main and a PR branch that change the same line of a.txt differently; the PR branch
# is checked out, as after "Prepare branch" in conflict mode.
setup() {
  current=$1
  repo=$(mktemp -d "$root/r.XXXXXX")
  export GITHUB_OUTPUT="$repo.out"; : > "$GITHUB_OUTPUT"
  git init -q "$repo"
  cd "$repo" || exit 1
  git config core.autocrlf false
  echo base > a.txt; git add a.txt; git commit -q -m base; git branch -M main
  git switch -q -c pr
  echo ticket > a.txt; git commit -q -am ticket; ticket=$(git rev-parse HEAD)
  git switch -q main
  echo main > a.txt; git commit -q -am main
  main=$(git rev-parse HEAD)
  git switch -q pr
}
# check: "Require main merged" alone. steps: "Finish merge" then "Require main merged", as the workflow
# runs them after "Resolve conflicts" (the second only when the first passed).
check() { out=$(bash "$script" check "$main" 2>&1); code=$?; }
steps() {
  local o1 o2 c
  o1=$(bash "$script" finish 2>&1); c=$?
  if [ "$c" -ne 0 ]; then out=$o1; code=$c; return; fi
  o2=$(bash "$script" check "$main" 2>&1); code=$?
  out="$o1
$o2"
}
merge_main() { git merge -q --no-edit main > /dev/null 2>&1; }

setup "a conflict-mode run that left the branch still conflicting with main is not a success"
# "Rebase onto main" merged and stopped on the conflict; the resolving agent did nothing.
merge_main
steps
eq exit 1 "$code"
has reason "충돌을 풀지 않고 끝남" "$out"
has "unmerged file" "a.txt" "$out"
has "reason output" "reason=충돌을 풀지 않고 끝남" "$(cat "$GITHUB_OUTPUT")"
eq "HEAD is still the ticket's commit" "$ticket" "$(git rev-parse HEAD)"

setup "no merge: the agent aborted it and the branch is the PR's old head"
merge_main; git merge --abort
steps
eq exit 1 "$code"
has reason "main($(git rev-parse --short "$main"))이 들어가지 않았다" "$out"

setup "merge in progress and resolved: the workflow makes the merge commit"
# The agent resolved the conflict, also changed another file, and ended without committing (#342).
merge_main
echo both > a.txt; git add a.txt; echo fix > e.txt
steps
eq exit 0 "$code"
eq "merge commit" "$main" "$(git rev-parse HEAD^2)"
eq "no merge left" "" "$(git rev-parse -q --verify MERGE_HEAD)"
eq "resolved content" both "$(git show HEAD:a.txt)"
eq "the agent's other change is in" fix "$(git show HEAD:e.txt 2>/dev/null)"
eq "clean tree" "" "$(git status --porcelain)"

setup "a file fixed on disk but never marked resolved (git add) fails the finish"
merge_main
echo both > a.txt
steps
eq exit 1 "$code"
has reason "풀리지 않은 파일이 남았다: a.txt" "$out"

setup "a conflict marker left in a resolved file fails the finish"
merge_main
printf '<<<<<<< HEAD\nticket\n=======\nmain\n>>>>>>> main\n' > a.txt; git add a.txt
steps
eq exit 1 "$code"
has reason "충돌 표지가 남았다: a.txt" "$out"
eq "no merge commit" "$(git rev-parse -q --verify MERGE_HEAD)" "$main"

setup "a lone separator line is a marker too"
merge_main
printf 'ticket\n=======\nmain\n' > a.txt; git add a.txt
steps
eq exit 1 "$code"
has reason "충돌 표지가 남았다" "$out"

setup "markers already in a file before the merge are not counted"
git switch -q main; printf 'doc\n=======\n' > m.md; git add m.md; git commit -q -m doc; main=$(git rev-parse HEAD)
git switch -q pr; merge_main
echo both > a.txt; git add a.txt
steps
eq exit 0 "$code"

setup "finish without a merge in progress does nothing"
merge_main; echo both > a.txt; git add a.txt; git commit -q --no-edit
before=$(git rev-parse HEAD)
out=$(bash "$script" finish 2>&1); code=$?
eq exit 0 "$code"
eq "HEAD unchanged" "$before" "$(git rev-parse HEAD)"

setup "merge in progress with the conflict resolved but not committed (check alone)"
merge_main
echo both > a.txt; git add a.txt
check
eq exit 1 "$code"
has reason "MERGE_HEAD" "$out"

setup "unmerged file left after the merge state is gone"
merge_main
rm .git/MERGE_HEAD
steps
eq exit 1 "$code"
has reason "풀리지 않은 파일" "$out"

setup "rebase stopped on the conflict"
git rebase main > /dev/null 2>&1
steps
eq exit 1 "$code"
has reason "rebase" "$out"

setup "conflict resolved and committed by the agent"
merge_main
echo both > a.txt; git add a.txt; git commit -q --no-edit
steps
eq exit 0 "$code"
eq "no reason" "" "$(cat "$GITHUB_OUTPUT")"

setup "the ticket's commits rebased onto main (normal mode)"
git reset -q --hard "$main"; echo other > b.txt; git add b.txt; git commit -q -m b
steps
eq exit 0 "$code"

setup "main moved after the rebase step: the recorded commit is what counts"
merge_main
echo both > a.txt; git add a.txt; git commit -q --no-edit
git switch -q main; echo later > d.txt; git add d.txt; git commit -q -m later; git switch -q pr
steps
eq exit 0 "$code"

cd "$root" || exit 1
echo "merge-check: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
