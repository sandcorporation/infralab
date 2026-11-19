#!/usr/bin/env bash
# Tests of .github/factory/workflow-guard.sh (a workflow file the Implementer cannot push, #389;
# catching up with main after a refusal, #417).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../workflow-guard.sh"
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
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output"
  mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls.log"; : > "$GITHUB_OUTPUT"
  jq -n '{number: 70, state: "open", body: "x", labels: [{name: "in-progress"}]}' > "$FAKE_GH/issue-70.json"
  # a repository whose branch changes a file
  repo="$tmp/repo"
  git init -q "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$repo" branch -M main
  git -C "$repo" switch -q -c work
}
labels() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-70.json"; }
commit_file() { mkdir -p "$repo/$(dirname "$1")"; echo x > "$repo/$1"; git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m c; }
comment_first() { jq -r '.[0].body | split("\n")[0]' "$FAKE_GH/comments-70.json" 2>/dev/null; }

setup "a diff with .github/workflows is handed to a person"
commit_file .github/workflows/x.yml
( cd "$repo" && bash "$script" check 70 main > "$tmp/log" 2>&1 ); eq "exit" 0 $?
eq "labels" "ready-for-human" "$(labels)"
eq "marker" "<!-- factory-human workflow-change -->" "$(comment_first)"
has "blocked" "blocked=true" "$(cat "$GITHUB_OUTPUT")"
eq "nothing dispatched" 0 "$(grep -c 'workflow run' "$FAKE_GH/calls.log")"
eq "no failure comment" 0 "$(jq '[.[] | select(.body | contains("factory-implementer"))] | length' "$FAKE_GH/comments-70.json")"

setup "a diff without it goes on"
commit_file backend/a.py
( cd "$repo" && bash "$script" check 70 main > "$tmp/log" 2>&1 ); eq "exit" 1 $?
eq "labels unchanged" "in-progress" "$(labels)"
has "not blocked" "blocked=false" "$(cat "$GITHUB_OUTPUT")"

setup "the push refusal is not a failure"
printf '%s\n' "! [remote rejected] agent/issue-70 -> agent/issue-70 (refusing to allow a GitHub App to create or update workflow \`.github/workflows/a.yml\` without \`workflows\` permission)" > "$tmp/push.log"
bash "$script" push-failed 70 "$tmp/push.log" > /dev/null 2>&1; eq "exit" 0 $?
eq "labels" "ready-for-human" "$(labels)"
eq "marker" "<!-- factory-human workflow-change -->" "$(comment_first)"

setup "another push error stays a failure"
echo "fatal: unable to access: Could not resolve host" > "$tmp/push.log"
bash "$script" push-failed 70 "$tmp/push.log" > /dev/null 2>&1; eq "exit" 1 $?
eq "labels unchanged" "in-progress" "$(labels)"

# push-retry (#417): a bare remote whose pre-receive hook refuses, as GitHub does for a token without
# `workflows` permission, any branch whose workflow files differ from main's (and every push while
# `always-refuse` is in it).
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
remote_setup() {
  setup "$1"
  remote="$tmp/origin.git"
  git init -q --bare "$remote"
  cat > "$remote/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
  [ "$ref" = refs/heads/main ] && continue
  if [ -f always-refuse ] || [ -n "$(git diff --name-only refs/heads/main "$new" -- .github/workflows/)" ]; then
    echo "refusing to allow a GitHub App to create or update workflow \`.github/workflows/a.yml\` without \`workflows\` permission"
    exit 1
  fi
done
HOOK
  chmod +x "$remote/hooks/pre-receive"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q origin main 2> /dev/null
  git -C "$repo" fetch -q origin
}
on_main() { # on_main <file> [content]: a commit lands on the remote's main (from another clone)
  other="$tmp/other"
  [ -d "$other" ] || git clone -q "$remote" "$other" 2> /dev/null
  git -C "$other" pull -q origin main 2> /dev/null
  mkdir -p "$other/$(dirname "$1")"; echo "${2:-y}" > "$other/$1"; git -C "$other" add -A
  git -C "$other" commit -q -m main; git -C "$other" push -q origin HEAD:main 2> /dev/null
}
retry() { # retry <mode> <push args...>: the first push, then push-retry when it fails
  ( cd "$repo" && git push "${@:2}" 2> "$tmp/push.log" ) && { echo pushed-first; return 0; }
  ( cd "$repo" && bash "$script" push-retry 70 "$tmp/push.log" "$@" > "$tmp/log" 2>&1 )
}
remote_head() { git -C "$remote" rev-parse -q --verify refs/heads/work; }
reason() { jq -r '.[0].body' "$FAKE_GH/comments-70.json" 2>/dev/null; }

remote_setup "main changed a workflow file meanwhile: rebase and push again"
commit_file backend/a.py
on_main .github/workflows/a.yml
retry implement --force origin work; eq "exit" 0 $?
eq "pushed the rebased head" "$(git -C "$repo" rev-parse HEAD)" "$(remote_head)"
eq "on today's main" "$(git -C "$remote" rev-parse main)" "$(git -C "$repo" rev-parse HEAD^)"
eq "labels unchanged" "in-progress" "$(labels)"
has "retried" "retried=true" "$(cat "$GITHUB_OUTPUT")"
has "not blocked" "blocked=false" "$(cat "$GITHUB_OUTPUT")"

remote_setup "the branch's own commit changes a workflow file: hand over at once"
commit_file .github/workflows/x.yml
on_main backend/b.py
retry implement --force origin work; eq "exit" 3 $?
eq "labels" "ready-for-human" "$(labels)"
has "blocked" "blocked=true" "$(cat "$GITHUB_OUTPUT")"
has "names the file" ".github/workflows/x.yml" "$(reason)"
eq "not pushed" "" "$(remote_head)"
eq "not rebased" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse HEAD^)"

remote_setup "a rebase conflict hands over"
commit_file backend/a.py
on_main backend/a.py other
on_main .github/workflows/a.yml
retry implement --force origin work; eq "exit" 3 $?
eq "labels" "ready-for-human" "$(labels)"
has "says why" "rebase 가 충돌" "$(reason)"
eq "no rebase left going" "" "$(ls "$repo/.git" | grep -E '^rebase-(merge|apply)$')"
eq "not pushed" "" "$(remote_head)"

remote_setup "a second refusal hands over"
commit_file backend/a.py
on_main .github/workflows/a.yml
touch "$remote/always-refuse"
retry implement --force origin work; eq "exit" 3 $?
eq "labels" "ready-for-human" "$(labels)"
has "says main was caught up with" "main 을 따라잡은 뒤에도" "$(reason)"
eq "no failure comment" 0 "$(jq '[.[] | select(.body | contains("factory-implementer"))] | length' "$FAKE_GH/comments-70.json")"

remote_setup "conflict mode merges main and pushes without force"
commit_file backend/a.py
git -C "$repo" push -q origin work 2> /dev/null
before=$(remote_head)
on_main .github/workflows/a.yml
commit_file backend/c.py
retry conflict origin work; eq "exit" 0 $?
eq "pushed the merge" "$(git -C "$repo" rev-parse HEAD)" "$(remote_head)"
eq "a merge commit" 2 "$(git -C "$repo" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ' | awk '{print $1-1}')"
eq "keeps the old head" 0 "$(git -C "$repo" merge-base --is-ancestor "$before" HEAD; echo $?)"
eq "labels unchanged" "in-progress" "$(labels)"

remote_setup "conflict mode: a merge conflict hands over"
commit_file backend/a.py
git -C "$repo" push -q origin work 2> /dev/null
on_main backend/a.py other
on_main .github/workflows/a.yml
commit_file backend/c.py
retry conflict origin work; eq "exit" 3 $?
has "says why" "merge 가 충돌" "$(reason)"
eq "no merge left going" "" "$(ls "$repo/.git" | grep -x MERGE_HEAD)"

remote_setup "another push error is a failure"
echo "fatal: unable to access: Could not resolve host" > "$tmp/push.log"
( cd "$repo" && bash "$script" push-retry 70 "$tmp/push.log" implement --force origin work > /dev/null 2>&1 ); eq "exit" 1 $?
eq "labels unchanged" "in-progress" "$(labels)"
has "not blocked" "blocked=false" "$(cat "$GITHUB_OUTPUT")"

# #492: the factory may push with GITHUB_TOKEN or with an App's token; the hand-over text does not say which.
current="no hand-over text names the token kind (#492)"
eq "GITHUB_TOKEN in a reason" 0 "$(grep -c 'handover .*GITHUB_TOKEN' "$here/../workflow-guard.sh")"

echo "workflow-guard.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
