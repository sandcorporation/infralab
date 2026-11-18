#!/usr/bin/env bash
# A workflow file the Implementer cannot push (ADR-0001, "workflow 파일은 사람 몫"). GITHUB_TOKEN may not
# create or update `.github/workflows/*` (GitHub: "refusing to allow a GitHub App to create or update
# workflow … without `workflows` permission"), so a ticket that needs it only fails at the push — three
# runs and about $8 on #53. This hands such a ticket to a person at once: no failure is counted, nothing
# is dispatched again.
#
#   workflow-guard.sh check <issue> <base>      the commits <base>..HEAD touch `.github/workflows/`
#   workflow-guard.sh push-failed <issue> <log> the push log holds that refusal
#
# Both: when it applies, hand-to-human.sh hands the issue to a person (`ready-for-human` replaces
# `in-progress`, a comment starting with `<!-- factory-human -->` gives the reason), `blocked=true` goes to $GITHUB_OUTPUT (stdout when unset)
# and the exit code is 0. Otherwise `blocked=false` and exit code 1 (the caller goes on / fails as before).
#
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
here=$(cd "$(dirname "$0")" && pwd)

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; else printf '%s\n' "$@"; fi
}

handover() { # handover <issue> <reason>
  bash "$here/hand-to-human.sh" "$1" "$2" || echo "::warning::workflow-guard: could not hand #$1 to a human"
  output blocked=true
}

case "${1:-}" in
  check)
    [ $# -eq 3 ] || { echo 'usage: workflow-guard.sh check <issue> <base>' >&2; exit 2; }
    files=$(git diff --name-only "$3"...HEAD -- .github/workflows/ | head -n 5 | tr '\n' ' ')
    if [ -n "$files" ]; then
      handover "$2" "사유: workflow 파일. 이 티켓은 \`.github/workflows/\` 를 바꾼다(${files% }). 공장의 push 토큰(App)에는 workflows 권한이 없어 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 0
    fi
    output blocked=false
    exit 1 ;;
  push-failed)
    [ $# -eq 3 ] || { echo 'usage: workflow-guard.sh push-failed <issue> <log>' >&2; exit 2; }
    if [ -f "$3" ] && grep -Eq 'refusing to allow a GitHub App to create or update workflow|without .?workflows.? permission' "$3"; then
      handover "$2" "사유: workflow 파일. push 가 workflow 파일 때문에 거절됐다(공장의 push 토큰(App)에 \`workflows\` 권한이 없다). 사람이 처리한다. 실패 횟수는 늘리지 않았고 다시 돌리지 않는다."
      exit 0
    fi
    output blocked=false
    exit 1 ;;
  *) echo 'usage: workflow-guard.sh check <issue> <base> | push-failed <issue> <log>' >&2; exit 2 ;;
esac
