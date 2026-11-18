#!/usr/bin/env bash
# The scripted half of the factory Odin run (factory-odin.yml, ADR-0001 "Odin").
#
#   odin.sh state <S>                   what the Odin run of spec #S has to do. Writes to $GITHUB_OUTPUT
#                                       (stdout when unset) mode=, pr= and branch=:
#                                         mode=none    no open spec PR (head factory/spec-<S>): warn and stop
#                                         mode=empty   the spec PR changes no file (Decompose wrote no test):
#                                                      no agent, `odin.sh empty`
#                                         mode=review  the agent reviews the spec PR
#   odin.sh verdict <S> [file]          after the agent: verdict=question when the spec has `needs-decision`
#                                       or the verdict file (default .factory/odin-verdict) says `question`;
#                                       verdict=go for `pass` / `fixed`; verdict=missing otherwise.
#   odin.sh question <S> <PR> [report]  the agent asked: comment the report on the spec PR. Nothing is
#                                       merged and no ticket is labelled; the run resumes when a person
#                                       answers and removes `needs-decision`.
#   odin.sh human <S> <PR> <reason>     hand the spec to a human: comment the reason (a file) on the spec
#                                       PR, label the spec `ready-for-human` and comment
#                                       `<!-- factory-human -->` with the reason on it. Nothing is merged.
#   odin.sh pass <S> <PR> [report]      the checks passed and the workflow pushed Odin's fixes: comment the
#                                       report on the spec PR, squash-merge it as the factory App once
#                                       ci.yml's required jobs are green (merge-pr.sh →
#                                       scripts/pr-merge.sh, #172), delete its branch and its job-less
#                                       bot ci.yml runs (prune-runs.sh), label the
#                                       spec's open tickets `ready-for-agent` and dispatch the first one
#                                       (dispatch-next.sh --tickets-only --candidates <them>: the
#                                       label search may lag, so the approved tickets are named: the
#                                       lowest-numbered approved ticket with no open blocker); release.yml
#                                       runs on the merge's push. Nothing else is done when the PR is not
#                                       merged: exit 1 when GitHub refused the merge (conflict path),
#                                       2 when the checks are red, unfinished or unregistered (a human).
#   odin.sh empty <S> <PR>              the spec PR has no test: close it and delete its branch, then
#                                       label the tickets and dispatch the first one as `pass` does.
#   odin.sh conflict <S> <PR> <files> <reason> [--dispatch]
#                                       the spec PR conflicts with main (; <files>: the conflicting
#                                       paths, one per line, may be empty when GitHub only refused the
#                                       merge). Counts the conflict rounds on the spec PR: comments starting
#                                       with `<!-- factory-odin-conflict -->` after the last hand-over to a
#                                       human (`<!-- factory-odin-human -->`). Under the limit it comments a
#                                       new round with the files, writes resolve=true and exits 0; with
#                                       --dispatch it also dispatches factory-odin.yml with mode=conflict
#                                       (that run merges main again and resolves without a new review). At
#                                       the limit, or when the dispatch fails, it writes the reason with the
#                                       files to <reason>, writes resolve=false and exits 1: the caller
#                                       runs `human`.
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN, BASE (default main); RUN_URL (link in comments,
# optional); FACTORY_DISPATCH_NEXT (command run instead of dispatch-next.sh, tests); FACTORY_PRUNE_RUNS
# (command run with the branch instead of prune-runs.sh, tests);
# FACTORY_APP_TOKEN, FACTORY_PR_MERGE and FACTORY_MERGE_WAIT (merge-pr.sh); ODIN_CONFLICT_LIMIT (conflict
# rounds before a human, default 2). Needs bash, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=merge-pr.sh
. "$here/merge-pr.sh"
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
BASE=${BASE:-main}
HUMAN='<!-- factory-human -->'
PR_HUMAN='<!-- factory-odin-human -->'
CONFLICT='<!-- factory-odin-conflict -->'
CONFLICT_LIMIT=${ODIN_CONFLICT_LIMIT:-2}

j() { jq "$@" | tr -d '\r'; }

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; else echo "$1"; fi
}

usage() {
  echo "usage: odin.sh state <S> | verdict <S> [file] | question <S> <PR> [report] | human <S> <PR> <reason> | pass <S> <PR> [report] | empty <S> <PR> | conflict <S> <PR> <files> <reason> [--dispatch]" >&2
  exit 2
}

branch_of() { echo "factory/spec-$1"; }
run_link() { [ -n "${RUN_URL:-}" ] && printf ' (%s)' "$RUN_URL"; }
comment() { gh api "repos/$REPO/issues/$1/comments" -f "body=$2" > /dev/null; }
add_label() { gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null; }
has_label() { # has_label <issue> <label>
  [ "$(gh api "repos/$REPO/issues/$1" | j -r --arg l "$2" 'any(.labels[]; .name == $l)')" = true ]
}
delete_branch() {
  gh api -X DELETE "repos/$REPO/git/refs/heads/$1" > /dev/null 2>&1 \
    || echo "::warning::could not delete branch $1"
}
# Delete the job-less ci.yml pull_request runs GitHub left on the spec PR branch (prune-runs.sh).
prune_runs() {
  if [ -n "${FACTORY_PRUNE_RUNS:-}" ]; then $FACTORY_PRUNE_RUNS "$1"; else bash "$here/prune-runs.sh" "$1"; fi
}

# Number of the open spec PR of a spec, empty when there is none (as decompose.sh finds it).
spec_pr() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -s -r --arg b "$(branch_of "$1")" \
      'add // [] | map(select(.state == "open" and .head.ref == $b)) | sort_by(.number) | .[0].number // empty'
}

# Open sub-issues of a spec, ascending.
open_tickets() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate \
    | j -s -r 'add // [] | map(select(.state == "open") | .number) | sort | .[]'
}

# --- state ---------------------------------------------------------------------------------------

state() {
  local s=$1 pr files
  pr=$(spec_pr "$s")
  output "branch=$(branch_of "$s")"
  if [ -z "$pr" ]; then
    echo "::warning::#$s has no open spec PR ($(branch_of "$s")); nothing for Odin to review"
    output mode=none
    return 0
  fi
  output "pr=$pr"
  files=$(gh api "repos/$REPO/pulls/$pr" | j -r '.changed_files // 0')
  if [ "${files:-0}" -eq 0 ]; then
    echo "::notice::spec PR #$pr changes no file; the tickets start without acceptance tests"
    output mode=empty
  else
    output mode=review
  fi
}

# --- verdict -------------------------------------------------------------------------------------

verdict() {
  local s=$1 file=${2:-.factory/odin-verdict} v
  v=$(tr -d '[:space:]' < "$file" 2> /dev/null || true)
  if has_label "$s" needs-decision || [ "$v" = question ]; then
    output verdict=question
  elif [ "$v" = pass ] || [ "$v" = fixed ]; then
    output verdict=go
  else
    echo "::warning::Odin left no verdict (${v:-nothing})"
    output verdict=missing
  fi
}

# --- question / human ----------------------------------------------------------------------------

question() {
  local s=$1 pr=$2 report=${3:-}
  if [ -n "$report" ] && [ -s "$report" ]; then
    comment "$pr" "Odin$(run_link): 질문으로 멈춤(#$s의 \`needs-decision\`)

$(cat "$report")" || echo "::warning::could not comment on PR #$pr"
  fi
  echo "::notice::#$s waits for an answer (needs-decision); spec PR #$pr stays open"
}

human() {
  local s=$1 pr=$2 file=$3 reason
  reason=$(cat "$file" 2> /dev/null)
  [ -n "$reason" ] || reason="(까닭이 남지 않았다)"
  comment "$pr" "$PR_HUMAN
Odin$(run_link): 병합하지 않음

$reason" || echo "::warning::could not comment on PR #$pr"
  add_label "$s" ready-for-human || echo "::warning::could not label #$s ready-for-human"
  comment "$s" "$HUMAN
Odin이 스펙 PR #$pr을 병합하지 못했다$(run_link). 공장은 이 spec을 더 돌리지 않는다: 사람이 아래 까닭을 보고 스펙 PR을 고친 뒤 \`ready-for-human\`을 떼고 Odin을 다시 돌린다(\`factory-odin.yml\`, 입력 spec=$s).

$reason"
  echo "#$s: handed to a human"
}

# --- approving the tickets -----------------------------------------------------------------------

start_chain() {
  local s=$1 n tickets
  tickets=$(open_tickets "$s")
  if [ -z "$tickets" ]; then
    echo "::warning::#$s has no open tickets to approve"
    return 0
  fi
  local approved=
  for n in $tickets; do
    # A ticket for workflow files stays with a person (local-ticket.sh).
    if [ "$(env -u GITHUB_OUTPUT bash "$here/local-ticket.sh" "$n" | sed -n 's/^local=//p' | tail -n 1)" = true ]; then
      echo "#$n changes workflow files: not approved, left to a local worker"
      continue
    fi
    approved="$approved $n"
    add_label "$n" ready-for-agent || echo "::warning::could not label #$n ready-for-agent"
  done
  echo "approved: $(echo $approved)"
  if [ -n "${FACTORY_DISPATCH_NEXT:-}" ]; then
    $FACTORY_DISPATCH_NEXT
  else
    bash "$here/dispatch-next.sh" --tickets-only --candidates "$(echo $approved)"
  fi
}

# --- pass ----------------------------------------------------------------------------------------

pass() {
  local s=$1 pr=$2 report=${3:-} rc
  if [ -n "$report" ] && [ -s "$report" ]; then
    comment "$pr" "Odin$(run_link): 통과

$(cat "$report")" || echo "::warning::could not comment on PR #$pr"
  fi
  # scripts/pr-merge.sh as the factory App: waits for ci.yml's required jobs to be green (#172).
  factory_merge "$pr"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::could not merge spec PR #$pr"
    return "$rc"
  fi
  delete_branch "$(branch_of "$s")"
  prune_runs "$(branch_of "$s")"
  # The App's merge is a push to main: release.yml (check + image → production) runs on it (#172).
  start_chain "$s"
}

# --- empty ---------------------------------------------------------------------------------------

empty() {
  local s=$1 pr=$2
  comment "$pr" "Odin$(run_link): 이 스펙 PR은 바꾼 파일이 없다(인수 시험 0개). 닫고 티켓을 인수 시험 없이 시작한다." \
    || echo "::warning::could not comment on PR #$pr"
  gh api -X PATCH "repos/$REPO/pulls/$pr" -f state=closed > /dev/null || echo "::warning::could not close PR #$pr"
  delete_branch "$(branch_of "$s")"
  prune_runs "$(branch_of "$s")"
  start_chain "$s"
}

# --- conflict -----------------------------------------------------------------------------

# Conflict rounds already spent on a spec PR since its last hand-over to a human. Only the factory's
# own comments count: on a public repository anyone could write the markers.
conflict_rounds() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate \
    | j -s -r --arg h "$PR_HUMAN" --arg c "$CONFLICT" --arg bot "${FACTORY_BOT:-github-actions[bot]}" \
      'add // [] | map(select((.user.login // "") == $bot and (.body // "" | type) == "string"))
       | ([to_entries[] | select(.value.body | startswith($h)) | .key] | max // -1) as $i
       | .[($i + 1):] | map(select(.body | startswith($c))) | length'
}

conflict() {
  local s=$1 pr=$2 files_file=$3 reason=$4 dispatch=${5:-} rounds list
  list=$(sed '/^[[:space:]]*$/d; s/\r$//; s/^/- /' "$files_file" 2> /dev/null)
  [ -n "$list" ] || list="- (충돌 파일을 알아내지 못했다: GitHub이 병합을 거절했다)"
  rounds=$(conflict_rounds "$pr")
  if [ -z "$rounds" ]; then
    echo "::warning::could not count the conflict rounds on PR #$pr; counting none"
    rounds=0
  fi
  if [ "$rounds" -ge "$CONFLICT_LIMIT" ]; then
    printf '### 스펙 PR이 %s와 충돌하는데 충돌 풀기 한도(%s회)를 다 썼다\n\n충돌 파일:\n\n%s\n' \
      "$BASE" "$CONFLICT_LIMIT" "$list" > "$reason"
    output resolve=false
    return 1
  fi
  # The comment is the round counter: without it the rounds would never reach the limit.
  if ! comment "$pr" "$CONFLICT
Odin$(run_link): $BASE와 충돌, 풀기 $((rounds + 1))/$CONFLICT_LIMIT

$list"; then
    printf '### 스펙 PR이 %s와 충돌하는데 충돌 풀기 횟수를 PR에 적지 못했다\n\n충돌 파일:\n\n%s\n' \
      "$BASE" "$list" > "$reason"
    output resolve=false
    return 1
  fi
  if [ "$dispatch" = --dispatch ]; then
    if gh api -X POST "repos/$REPO/actions/workflows/factory-odin.yml/dispatches" \
      -f "ref=$BASE" -f "inputs[spec]=$s" -f "inputs[mode]=conflict" > /dev/null; then
      echo "dispatched factory-odin.yml for #$s (mode=conflict)"
    else
      printf '### 스펙 PR이 %s와 충돌해 충돌 풀기 run을 dispatch하려 했으나 실패했다\n\n충돌 파일:\n\n%s\n' \
        "$BASE" "$list" > "$reason"
      output resolve=false
      return 1
    fi
  fi
  output resolve=true
}

: "${REPO:?REPO is not set}"
case "${1:-}" in
  state) [ $# -eq 2 ] || usage; state "$2" ;;
  verdict) [ $# -ge 2 ] || usage; verdict "$2" "${3:-}" ;;
  question) [ $# -ge 3 ] || usage; question "$2" "$3" "${4:-}" ;;
  human) [ $# -eq 4 ] || usage; human "$2" "$3" "$4" ;;
  pass) [ $# -ge 3 ] || usage; pass "$2" "$3" "${4:-}" ;;
  empty) [ $# -eq 3 ] || usage; empty "$2" "$3" ;;
  conflict)
    [ $# -eq 5 ] || { [ $# -eq 6 ] && [ "$6" = --dispatch ]; } || usage
    conflict "$2" "$3" "$4" "$5" "${6:-}" ;;
  *) usage ;;
esac
