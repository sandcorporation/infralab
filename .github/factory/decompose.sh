#!/usr/bin/env bash
# State and wrap-up of the Decompose stage (factory-decompose.yml, ADR-0001 "Decompose").
#
#   decompose.sh state <S>          decide what the Decompose run of spec #S has to do. Writes to
#                                   $GITHUB_OUTPUT (stdout when unset):
#                                     mode=question    the spec has `needs-decision`: wait for the answer
#                                     mode=specpr      an open spec PR (head factory/spec-<S>) exists: no agent,
#                                                      only dispatch Odin
#                                     mode=new         the spec has no sub-issues: create tickets and their tests
#                                     mode=decomposed  some open ticket has no acceptance test in the checkout
#                                                      (no marker of #N, spec-tests.sh): write only those
#                                     mode=done        every open ticket already has its tests: nothing to do
#                                   and tickets=<open tickets without tests, space-separated> (decomposed),
#                                   pr=<spec PR number> (specpr).
#   decompose.sh finish <S> <mode>  after the agent. In decomposed mode first removes `ready-for-agent` from the
#                                   spec's open tickets (Odin labels them again). Then, when the spec has
#                                   `needs-decision`, stops: result=question, no commit, no PR, no dispatch.
#                                   Otherwise commits the acceptance tests (SPEC_PATHSPECS of spec-tests.sh only) on
#                                   factory/spec-<S>, pushes it, opens the spec PR (title "스펙: <title> 인수 시험
#                                   (#S)", label `spec-pr`, body `Refs #S` and the ticket list) and dispatches Odin:
#                                   result=pr, pr=<number>.
#   decompose.sh dispatch-odin <S>  dispatch factory-odin.yml with input spec=<S>. A failed dispatch (the workflow
#                                   does not exist yet, or is disabled) only warns.
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN, BASE (base branch, default main), FACTORY_ROOT (the
# checkout to search and commit in, default the repository this script is in). Needs bash, git, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
BASE=${BASE:-main}
ROOT=${FACTORY_ROOT:-$(cd "$here/../.." && pwd)}
# shellcheck source=spec-tests.sh
. "$here/spec-tests.sh"

# Strip any CR jq prints (CRLF output on some platforms).
j() { jq "$@" | tr -d '\r'; }

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; else echo "$1"; fi
}

branch_of() { echo "factory/spec-$1"; }

has_label() { # has_label <issue> <label>
  [ "$(gh api "repos/$REPO/issues/$1" | j -r --arg l "$2" 'any(.labels[]; .name == $l)')" = true ]
}

# Open sub-issues of a spec, ascending, one per line.
open_tickets() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate \
    | j -s -r 'add // [] | map(select(.state == "open") | .number) | sort | .[]'
}

sub_issue_count() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate | j -s 'add // [] | length'
}

# Number of the open spec PR of a spec, empty when there is none.
spec_pr() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -s -r --arg b "$(branch_of "$1")" \
      'add // [] | map(select(.state == "open" and .head.ref == $b)) | sort_by(.number) | .[0].number // empty'
}

# Whether the checkout has an acceptance test of ticket #N.
has_tests() { spec_has_tests "$ROOT" "$1"; }

state() {
  local s=$1 pr n missing=
  if has_label "$s" needs-decision; then output mode=question; return; fi
  pr=$(spec_pr "$s")
  if [ -n "$pr" ]; then output mode=specpr; output "pr=$pr"; return; fi
  if [ "$(sub_issue_count "$s")" -eq 0 ]; then output mode=new; return; fi
  for n in $(open_tickets "$s"); do
    has_tests "$n" || missing="$missing $n"
  done
  missing=${missing# }
  if [ -n "$missing" ]; then
    output mode=decomposed
    output "tickets=$missing"
  else
    output mode=done
  fi
}

dispatch_odin() {
  if gh api -X POST "repos/$REPO/actions/workflows/factory-odin.yml/dispatches" \
    -f "ref=$BASE" -f "inputs[spec]=$1" > /dev/null; then
    echo "dispatched factory-odin.yml for #$1"
  else
    echo "::warning::could not dispatch factory-odin.yml for #$1 (missing or disabled?)"
  fi
}

finish() {
  local s=$1 mode=$2 n tickets branch title list body pr
  tickets=$(open_tickets "$s")
  # A ticket that changes `.github/workflows/` stays out of the factory (local-ticket.sh).
  for n in $tickets; do
    env -u GITHUB_OUTPUT bash "$here/local-ticket.sh" "$n" > /dev/null || echo "::warning::could not check #$n for workflow files"
  done
  if [ "$mode" = decomposed ]; then
    for n in $tickets; do
      if has_label "$n" ready-for-agent; then
        gh api -X DELETE "repos/$REPO/issues/$n/labels/ready-for-agent" > /dev/null \
          || echo "::warning::could not remove ready-for-agent from #$n"
      fi
    done
  fi
  if has_label "$s" needs-decision; then
    echo "::notice::#$s asks a question (needs-decision); no spec PR"
    output result=question
    return 0
  fi
  if [ -z "$tickets" ]; then
    echo "::error::#$s has no open tickets after Decompose"
    return 1
  fi

  title=$(gh api "repos/$REPO/issues/$s" | j -r '.title')
  list=$(for n in $tickets; do echo "- #$n"; done)
  branch=$(branch_of "$s")
  (
    cd "$ROOT" || exit 1
    git checkout -q -B "$branch" || exit 1
    files=$(git ls-files -m -o -d --exclude-standard -- "${SPEC_PATHSPECS[@]}")
    if [ -n "$files" ]; then
      # shellcheck disable=SC2086 # repository paths without spaces, one per line
      git add -A -- $files || exit 1
    fi
    other=$(git status --porcelain --untracked-files=all | grep -vE "^[AMD]  ${SPEC_PATH_RE#^}")
    if [ -n "$other" ]; then
      echo "::warning::Decompose changed files outside the acceptance tests; not committed:"
      echo "$other"
    fi
    if git diff --cached --quiet; then
      echo "::warning::Decompose wrote no acceptance tests for #$s; the spec PR has only an empty commit"
    fi
    git -c user.name='sandcorp-factory[bot]' \
      -c user.email='358343752+sandcorp-factory[bot]@users.noreply.github.com' \
      commit -q --allow-empty -m "스펙: $title 인수 시험 (#$s)" -m "$list" || exit 1
    # as the factory App, so ci.yml runs on the spec PR (#172)
    bash "$here/app-push.sh" -q origin "HEAD:refs/heads/$branch"
  ) || { echo "::error::could not commit or push $branch"; return 1; }

  body="Refs #$s

Decompose가 쓴 티켓별 인수 시험(꺼 둔 시험, 표식 \`#<티켓>\` — docs/adr/0001-software-factory.md 「인수 시험」)이다. Odin이 검토·고침 뒤 병합한다.

## 티켓

$list"
  # Opened by the factory App (#172): a GITHUB_TOKEN PR gets no ci.yml run. Labels stay GITHUB_TOKEN.
  pr=$(GH_TOKEN=${FACTORY_APP_TOKEN:-} gh api "repos/$REPO/pulls" -f "title=스펙: $title 인수 시험 (#$s)" -f "head=$branch" -f "base=$BASE" \
    -f "body=$body" | j -r '.number // empty')
  if [ -z "$pr" ]; then echo "::error::could not open the spec PR of #$s"; return 1; fi
  gh api "repos/$REPO/issues/$pr/labels" -f 'labels[]=spec-pr' > /dev/null \
    || echo "::warning::could not label PR #$pr spec-pr"
  echo "opened spec PR #$pr"
  output result=pr
  output "pr=$pr"
  dispatch_odin "$s"
}

usage() {
  echo "usage: decompose.sh state <S> | finish <S> <mode> | dispatch-odin <S>" >&2
  exit 2
}

: "${REPO:?REPO is not set}"
case "${1:-}" in
  state) [ $# -eq 2 ] || usage; state "$2" ;;
  finish) [ $# -eq 3 ] || usage; finish "$2" "$3" ;;
  dispatch-odin) [ $# -eq 2 ] || usage; dispatch_odin "$2" ;;
  *) usage ;;
esac
