#!/usr/bin/env bash
# Resume of a stopped spec (factory-resume.yml, ADR-0001 "재개").
#
#   resume.sh <S>
#
# Runs when a person removes `needs-decision` or `factory-paused` from spec #S (or by hand). Decides the
# stage the spec stopped at and dispatches it:
#
#   1. ledger.sh guard <S> still says no (another stop label is left, or a budget is spent): nothing.
#   2. decompose.sh state <S>:
#        new / decomposed / question   dispatch factory-decompose.yml (issue=<S>). `question` cannot remain
#                                      after the guard; it means the answer arrived, so decompose again.
#        specpr                        dispatch Odin (decompose.sh dispatch-odin <S>).
#        done                          the tickets are approved. When an open ticket of the spec is
#                                      `in-progress` and has an open PR the Implementer finished (body
#                                      `Closes #N` and `<!-- factory-checked <sha> -->`), dispatch
#                                      factory-verify.yml (issue=<N>, pr=<PR>); otherwise dispatch-next.sh.
#
# Prints action=<what it did> (skip|decompose|odin|verify|next) to $GITHUB_OUTPUT (stdout when unset).
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN, BASE (default main), the variables of ledger.sh,
# decompose.sh (FACTORY_ROOT: the checkout decompose.sh state searches) and dispatch-next.sh.
# FACTORY_DISPATCH_NEXT replaces dispatch-next.sh (tests). Needs bash, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
export REPO
BASE=${BASE:-main}
DISPATCH_NEXT=${FACTORY_DISPATCH_NEXT:-$here/dispatch-next.sh}

# Strip any CR jq prints (CRLF output on some platforms).
j() { jq "$@" | tr -d '\r'; }

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; else echo "$1"; fi
}

# value <key> <file>: the last key=value line of a GITHUB_OUTPUT-style file.
value() { sed -n "s/^$1=//p" "$2" | tail -n 1; }

# dispatch <workflow file> <name=value>...: workflow_dispatch on BASE with the given inputs.
dispatch() {
  local wf=$1 args=() kv
  shift
  for kv in "$@"; do args+=(-f "inputs[${kv%%=*}]=${kv#*=}"); done
  if gh api -X POST "repos/$REPO/actions/workflows/$wf/dispatches" -f "ref=$BASE" "${args[@]}" > /dev/null; then
    echo "dispatched $wf ($*)"
  else
    echo "::error::could not dispatch $wf ($*)"
    return 1
  fi
}

# The Implementer's open PR of ticket #N (number), empty when there is none.
checked_pr() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -s -r --arg n "$1" '
        add // [] | map(select(.state == "open"
          and ((.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?) #" + $n + "\\b"))
          and ((.body // "") | contains("<!-- factory-checked "))))
        | sort_by(.number) | .[0].number // empty'
}

# The spec's open tickets that are in progress, ascending.
in_progress_tickets() {
  local n
  for n in $(gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate \
    | j -s -r 'add // [] | map(select(.state == "open") | .number) | sort | .[]'); do
    if [ "$(gh api "repos/$REPO/issues/$n" | j -r 'any(.labels[]; .name == "in-progress")')" = true ]; then
      echo "$n"
    fi
  done
}

resume() {
  local s=$1 tmp go reason mode n pr
  tmp=$(mktemp)
  GITHUB_OUTPUT=$tmp bash "$here/ledger.sh" guard "$s" > /dev/null
  go=$(value go "$tmp")
  reason=$(value reason "$tmp")
  : > "$tmp"
  if [ "$go" != true ]; then
    rm -f "$tmp"
    echo "::notice::spec #$s does not resume yet (${reason:-guard failed})"
    output action=skip
    return 0
  fi

  GITHUB_OUTPUT=$tmp bash "$here/decompose.sh" state "$s" > /dev/null
  mode=$(value mode "$tmp")
  rm -f "$tmp"
  echo "spec #$s: mode=${mode:-?}"
  case "$mode" in
    new | decomposed | question)
      dispatch factory-decompose.yml "issue=$s" || return 1
      output action=decompose ;;
    specpr)
      bash "$here/decompose.sh" dispatch-odin "$s"
      output action=odin ;;
    done)
      for n in $(in_progress_tickets "$s"); do
        pr=$(checked_pr "$n")
        if [ -n "$pr" ]; then
          dispatch factory-verify.yml "issue=$n" "pr=$pr" || return 1
          output action=verify
          return 0
        fi
      done
      bash "$DISPATCH_NEXT" || return 1
      output action=next ;;
    *)
      echo "::error::could not decide the state of spec #$s"
      return 1 ;;
  esac
}

: "${REPO:?REPO is not set}"
[ $# -eq 1 ] || { echo "usage: resume.sh <spec>" >&2; exit 2; }
resume "$1"
