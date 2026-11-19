#!/usr/bin/env bash
# A workflow file the Implementer cannot push (ADR-0001, "workflow 파일은 사람 몫"). The factory's push
# token (GITHUB_TOKEN, or an App's token without `workflows` permission) may not create or update
# `.github/workflows/*` (GitHub: "refusing to allow a GitHub App to create or update
# workflow … without `workflows` permission"), so a ticket that needs it only fails at the push, and
# counting that as a code failure retries it (a port of this factory lost several runs that way, #389).
# This hands such a ticket to a person at once: no failure is counted, nothing is dispatched again.
#
#   workflow-guard.sh check <issue> <base>      the commits <base>..HEAD touch `.github/workflows/`
#   workflow-guard.sh push-failed <issue> <log> the push log holds that refusal
#   workflow-guard.sh push-retry <issue> <log> <mode> <push args...>
#                                               the push log holds that refusal: catch up with main and
#                                               push once more (#417), else hand over (below)
#
# check and push-failed: when it applies, hand-to-human.sh hands the issue to a person with the reason (code workflow-change, or push-rejected when the push-retry already failed), `blocked=true` goes to $GITHUB_OUTPUT (stdout when unset)
# and the exit code is 0. Otherwise `blocked=false` and exit code 1 (the caller goes on / fails as before).
#
# push-retry (#417): the refusal also comes when the branch touches no workflow file but main changed
# one after the branch was made (a merge landed during the run): the pushed ref then reverts main's
# workflow files. So: `git fetch origin main`; if the branch's own commits (`origin/main...HEAD`) touch
# `.github/workflows/`, hand over as before. Otherwise catch up with main and run `git push <push
# args>` once more: <mode> `conflict` merges (`git merge --no-edit origin/main`, as conflict mode
# already does: history is kept and the plain push still refuses to drop someone else's commits,
# #504), any other mode rebases (the fresh branch is force-pushed anyway). A merge/rebase conflict or a
# second refusal hands over, saying main was caught up with. Exit codes: 0 pushed after catching up
# (`blocked=false`, `retried=true`: open the PR), 3 handed over (`blocked=true`), 1 not that refusal
# or the second push failed otherwise (`blocked=false`: a failure as before), 2 usage.
#
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
here=$(cd "$(dirname "$0")" && pwd)

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; else printf '%s\n' "$@"; fi
}

handover() { # handover <issue> <code> <reason>
  bash "$here/hand-to-human.sh" "$1" "$2" "$3" || echo "::warning::workflow-guard: could not hand #$1 to a human"
  output blocked=true
}

refused() { # refused <log>: the push log holds GitHub's refusal of a workflow file
  [ -f "$1" ] && grep -Eq 'refusing to allow a GitHub App to create or update workflow|without .?workflows.? permission' "$1"
}

case "${1:-}" in
  check)
    [ $# -eq 3 ] || { echo 'usage: workflow-guard.sh check <issue> <base>' >&2; exit 2; }
    files=$(git diff --name-only "$3"...HEAD -- .github/workflows/ | head -n 5 | tr '\n' ' ')
    if [ -n "$files" ]; then
      handover "$2" workflow-change "사유: workflow 파일. 이 티켓은 \`.github/workflows/\` 를 바꾼다(${files% }). 공장이 push 에 쓰는 토큰은 workflow 파일을 push 할 수 없어 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 0
    fi
    output blocked=false
    exit 1 ;;
  push-failed)
    [ $# -eq 3 ] || { echo 'usage: workflow-guard.sh push-failed <issue> <log>' >&2; exit 2; }
    if refused "$3"; then
      handover "$2" workflow-change "사유: workflow 파일. push 가 workflow 파일 때문에 거절됐다(공장이 push 에 쓰는 토큰에 `workflows` 권한이 없다). 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 0
    fi
    output blocked=false
    exit 1 ;;
  push-retry)
    [ $# -ge 5 ] || { echo 'usage: workflow-guard.sh push-retry <issue> <log> <mode> <push args...>' >&2; exit 2; }
    issue=$2 log=$3 mode=$4
    shift 4
    if ! refused "$log"; then output blocked=false; exit 1; fi
    if ! git fetch -q origin main; then
      handover "$issue" push-rejected "사유: workflow 파일. push 가 workflow 파일 때문에 거절됐고 main 을 받아 오지 못해 다시 시도하지 못했다. 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 3
    fi
    files=$(git diff --name-only origin/main...HEAD -- .github/workflows/ | head -n 5 | tr '\n' ' ')
    if [ -n "$files" ]; then
      handover "$issue" workflow-change "사유: workflow 파일. 이 티켓은 \`.github/workflows/\` 를 바꾼다(${files% }). push 가 거절됐고 공장이 push 에 쓰는 토큰은 workflow 파일을 push 할 수 없어 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 3
    fi
    caught=true
    if [ "$mode" = conflict ]; then
      how='merge'
      git merge -q --no-edit origin/main > /dev/null 2>&1 || { git merge --abort > /dev/null 2>&1; caught=false; }
    else
      how='rebase'
      git rebase -q origin/main > /dev/null 2>&1 || { git rebase --abort > /dev/null 2>&1; caught=false; }
    fi
    if [ "$caught" = false ]; then
      handover "$issue" push-rejected "사유: workflow 파일. push 가 workflow 파일 때문에 거절됐다(그 사이 main 이 workflow 파일을 바꾼 듯하다). main 을 따라잡으려 했지만 $how 가 충돌했다. 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 3
    fi
    echo "::notice::workflow-guard: push refused over workflow files; caught up with main ($how), pushing again"
    if git push "$@" 2> "$log"; then
      cat "$log"
      output blocked=false retried=true
      exit 0
    fi
    cat "$log"
    if refused "$log"; then
      handover "$issue" push-rejected "사유: workflow 파일. push 가 workflow 파일 때문에 거절됐고, main 을 따라잡은 뒤에도($how) 거절됐다(공장이 push 에 쓰는 토큰에 `workflows` 권한이 없다). 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 3
    fi
    output blocked=false
    exit 1 ;;
  *) echo 'usage: workflow-guard.sh check <issue> <base> | push-failed <issue> <log> | push-retry <issue> <log> <mode> <push args...>' >&2; exit 2 ;;
esac
