#!/usr/bin/env bash
# The scripted half of the factory Verify run (factory-verify.yml, ADR-0001 "Verify").
#
#   verify.sh mech <N> <base>            machine checks of ticket #N's branch (the checkout's HEAD)
#                                        against <base> (origin/main), with the conventions of
#                                        spec-tests.sh. Prints every problem and exits 1 when there is one:
#                                        1. no marker of #N is left in any tracked file
#                                           (`@pytest.mark.skip(reason="#N")`, `t.Skip("#N")`,
#                                           `it.skip(… // #N`): every acceptance test of #N is on;
#                                        2. the branch's change to the acceptance-test files
#                                           (SPEC_PATHSPECS, `git diff <base>...HEAD`) only switches #N's
#                                           tests on: deletes its backend and agent marker lines and turns
#                                           each web `it.skip(… // #N` line into the same line without
#                                           `.skip` and the comment. Any other added, deleted or changed
#                                           line (an assertion, a removed test, another ticket's marker)
#                                           is "the acceptance test changed";
#                                        3. no stub of #N (`raise NotImplementedError("#N")`,
#                                           `throw new Error("#N")`, `panic("#N")`: Odin's placeholders
#                                           for the names of ticket #N's contract) is left.
#   verify.sh sendback <N> <PR> <file> [kind]
#                                        send ticket #N back with the reason (<file>), drop
#                                        `in-progress`. <kind> is `acceptance` (default: machine
#                                        checks, acceptance review, merge) or `conflict` (the branch
#                                        does not go onto today's main: conflict, rebase-ci, push).
#                                        The comment starts with the marker
#                                        `<!-- factory-sendback kind=<kind> pr=<PR> -->`.
#                                        acceptance: close the PR, delete its branch and its job-less
#                                        bot ci.yml runs (prune-runs.sh); the Implementer starts over.
#                                        conflict: keep the PR and its branch; the Implementer only
#                                        merges main into it and resolves (verify.sh conflict-pr).
#                                        Each kind has its own limit (ACCEPTANCE_LIMIT 2,
#                                        CONFLICT_LIMIT 3; an old marker without kind= counts as
#                                        acceptance): on reaching it hand the ticket to a human
#                                        (`ready-for-human`, `<!-- factory-human -->` naming the limit)
#                                        and move the chain on (dispatch-next.sh); otherwise label it
#                                        `ready-for-agent` again and run dispatch-next.sh --first <N>
#                                        (the ticket first, into an empty Implementer track).
#   verify.sh conflict-pr <N>            the PR the Implementer resolves instead of implementing
#                                        again: printed when ticket #N's last send-back is kind=conflict
#                                        and its PR is still open; nothing otherwise.
#   verify.sh next-verify [PR]           when no other Verify run is going, dispatch Verify for the
#                                        oldest open PR still waiting for one (not [PR]); the guard
#                                        against a lost pending run.
#   verify.sh pass <N> <PR> [report]     squash-merge the PR (retrying while GitHub computes
#                                        mergeability), delete its branch and its job-less bot
#                                        ci.yml runs (prune-runs.sh), comment the report on the
#                                        PR, stack its `사람 확인` items on the spec's check issue
#                                        (human-check.sh stack), close the ticket, dispatch release.yml on main
#                                        and then the next ticket (dispatch-next.sh). Exits 1 when the
#                                        PR could not be merged (nothing else is done then).
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN; RUN_URL (link in comments, optional);
# FACTORY_DISPATCH_NEXT (command run instead of dispatch-next.sh, tests); FACTORY_PRUNE_RUNS (command
# run with the branch instead of prune-runs.sh, tests); FACTORY_MERGE_WAIT
# (seconds between merge attempts, default 15). Needs bash, git, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=spec-tests.sh
. "$here/spec-tests.sh"
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
# Every send-back comment starts with this; `kind=` follows since  (none: acceptance).
SENDBACK='<!-- factory-sendback'
HUMAN='<!-- factory-human -->'
# Send-backs of one kind that hand the ticket to a human (decision 2026-11-18): a failed
# acceptance twice, a conflict with main three times. Conflicts are mostly the other track's luck,
# not the ticket's fault, and resolving one does not implement the ticket again.
ACCEPTANCE_LIMIT=2
CONFLICT_LIMIT=3

j() { jq "$@" | tr -d '\r'; }

usage() {
  echo "usage: verify.sh mech <N> <base> | sendback <N> <PR> <reason file> [acceptance|conflict] | conflict-pr <N> | pass <N> <PR> [report file] | next-verify [skip PR]" >&2
  exit 2
}

# --- mech ----------------------------------------------------------------------------------------

# grep_left <title> <git grep args…>: list the matching lines of HEAD under <title>; 1 when any.
grep_left() {
  local title=$1 left
  shift
  left=$(git grep -n "$@" | sed 's/^HEAD://')
  [ -n "$left" ] || return 0
  echo "- $title:"
  printf '%s\n' "$left" | sed 's/^/  - /'
  return 1
}

mech() {
  local n=$1 base=$2 problems=0 line file body trimmed key
  local py go web_re
  py=$(spec_py_marker "$n") go=$(spec_go_marker "$n") web_re=$(spec_web_marker_re "$n")

  grep_left "이 티켓의 인수 시험이 꺼진 채 남아 있다(\`$py\`·\`$go\`·\`it.skip(… // #$n\`을 모두 켜야 한다)" \
    -e "$py" -e "$go" -F HEAD -- '*.py' '*.go' || problems=1
  grep_left "이 티켓의 web 인수 시험이 꺼진 채 남아 있다(\`it.skip(\`→\`it(\`, \`// #$n\` 지우기)" \
    -E -e "$web_re" HEAD -- '*.ts' '*.tsx' || problems=1

  # Odin stubs the contract names the acceptance tests use (odin.md); the ticket replaces every one.
  grep_left "이 티켓의 스텁이 남아 있다(계약의 이름을 실제로 구현해야 한다)" \
    -F -e "$(spec_py_stub "$n")" -e "$(spec_ts_stub "$n")" -e "$(spec_go_stub "$n")" \
    HEAD -- '*.py' '*.go' '*.ts' '*.tsx' || problems=1

  # Only switching this ticket's tests on may touch the acceptance tests. A web marker line comes
  # back as an added line without `.skip` and the comment; `expect` holds those, one per line as
  # "<file>\t<line>", until the matching addition consumes them.
  local expect=
  file=
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
      'diff --git '*) file=${line##* b/} ;;
      '+++ '* | '--- '* | '@@ '*) ;;
      +*)
        body=${line#+}
        key="$file"$'\t'"$body"
        if printf '%s\n' "$expect" | grep -qxF -- "$key"; then
          expect=$(printf '%s\n' "$expect" | awk -v k="$key" '!done && $0 == k { done = 1; next } { print }')
        else
          echo "- 인수 시험을 고쳤다(줄을 더함) $file: \`$body\`"
          problems=1
        fi ;;
      -*)
        body=${line#-}
        trimmed=$(printf '%s' "$body" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ "$trimmed" = "$py" ] || [ "$trimmed" = "$go" ]; then
          :
        elif printf '%s' "$body" | grep -Eq -- "$web_re"; then
          expect="$expect"$'\n'"$file"$'\t'"$(spec_web_enabled "$body" "$n")"
        elif printf '%s' "$trimmed" | grep -Eq -e "$SPEC_ANY_PY_RE" -e "$SPEC_ANY_GO_RE" -e "$SPEC_ANY_WEB_RE"; then
          echo "- 다른 티켓의 인수 시험을 켰다 $file: \`$trimmed\`"
          problems=1
        else
          echo "- 인수 시험을 고쳤다(줄을 지움) $file: \`$body\`"
          problems=1
        fi ;;
    esac
  done < <(git diff --unified=0 --no-color --no-ext-diff --no-renames "$base"...HEAD -- "${SPEC_PATHSPECS[@]}")
  while IFS=$'\t' read -r file body; do
    [ -n "$file" ] || continue
    echo "- 인수 시험을 지웠다(켜지 않고 줄을 지움) $file: \`it(\` 줄이 없다: \`$body\`"
    problems=1
  done <<< "$expect"

  if [ "$problems" -ne 0 ]; then return 1; fi
  echo "기계 검사 통과: #$n의 꺼 둔 표식·스텁 없음, 인수 시험의 변경은 이 티켓의 시험 켜기뿐"
}

# --- GitHub helpers ------------------------------------------------------------------------------

comment() { gh api "repos/$REPO/issues/$1/comments" -f "body=$2" >/dev/null; }
add_label() { gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" >/dev/null; }
remove_label() { gh api -X DELETE "repos/$REPO/issues/$1/labels/$2" >/dev/null 2>&1 || true; }
dispatch() { # dispatch <workflow file> [<input>=<value> ...]
  local wf=$1; shift
  local args=() kv
  for kv in "$@"; do args+=(-f "inputs[${kv%%=*}]=${kv#*=}"); done
  gh api -X POST "repos/$REPO/actions/workflows/$wf/dispatches" -f ref=main "${args[@]}" >/dev/null
}
# Delete the job-less ci.yml pull_request runs GitHub left on a factory PR branch (prune-runs.sh).
prune_runs() {
  [ -n "$1" ] || return 0
  if [ -n "${FACTORY_PRUNE_RUNS:-}" ]; then $FACTORY_PRUNE_RUNS "$1"; else bash "$here/prune-runs.sh" "$1"; fi
}
next_ticket() {
  if [ -n "${FACTORY_DISPATCH_NEXT:-}" ]; then
    $FACTORY_DISPATCH_NEXT "$@"
  else
    bash "$here/dispatch-next.sh" "$@"
  fi
}
pr_branch() { gh api "repos/$REPO/pulls/$1" | j -r '.head.ref // empty'; }
delete_branch() {
  [ -n "$1" ] || return 0
  gh api -X DELETE "repos/$REPO/git/refs/heads/$1" >/dev/null 2>&1 || echo "::warning::could not delete branch $1"
}
# sendbacks <N>: the ticket's send-back comments, oldest first, as JSON lines {kind, pr}
# (a marker without kind= is an acceptance send-back from before ).
sendbacks() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate \
    | j -c -s --arg m "$SENDBACK" '.[][] | .body | select(startswith($m)) | split("\n")[0]
        | {kind: ((capture("kind=(?<k>[a-z]+)").k) // "acceptance"),
           pr: ((capture("pr=(?<p>[0-9]+)").p) // null)}'
}
sendback_count() { # sendback_count <N> <kind>
  sendbacks "$1" | j -s --arg k "$2" '[.[] | select(.kind == $k)] | length'
}
run_link() { [ -n "${RUN_URL:-}" ] && printf ' (%s)' "$RUN_URL"; }

# --- sendback ------------------------------------------------------------------------------------

sendback() {
  local n=$1 pr=$2 file=$3 kind=${4:-acceptance} reason branch count limit what next
  case "$kind" in acceptance | conflict) ;; *) usage ;; esac
  reason=$(cat "$file" 2>/dev/null)
  [ -n "$reason" ] || reason="(사유가 남지 않았다)"

  if [ "$kind" = conflict ]; then
    limit=$CONFLICT_LIMIT what="main과의 충돌"
    next="PR #$pr과 그 브랜치는 그대로 둔다. Implementer가 다시 구현하지 않고 그 브랜치에 main을 merge해 충돌만 푼다."
  else
    limit=$ACCEPTANCE_LIMIT what="인수 실패"
    next="PR #$pr을 닫았다. Implementer가 오늘의 main에서 다시 구현한다."
  fi
  comment "$n" "$SENDBACK kind=$kind pr=$pr -->
Verify가 PR #$pr을 되돌렸다($what)$(run_link). $next

$reason"
  if [ "$kind" = acceptance ]; then
    branch=$(pr_branch "$pr")
    gh api -X PATCH "repos/$REPO/pulls/$pr" -f state=closed >/dev/null || echo "::warning::could not close PR #$pr"
    delete_branch "$branch"
    prune_runs "$branch"
  else
    unmark_checked "$pr"
  fi
  remove_label "$n" in-progress

  count=$(sendback_count "$n" "$kind")
  if [ "${count:-0}" -ge "$limit" ]; then
    add_label "$n" ready-for-human
    comment "$n" "$HUMAN
Verify가 이 티켓을 ${what}로 ${count}번 되돌렸다(사람 넘김 한도: ${what} ${limit}번). 공장은 더 돌리지 않는다: 사람이 위 되돌림 사유를 보고 티켓이나 인수 시험을 고치거나 충돌을 푼 뒤 \`ready-for-human\`을 떼고 \`ready-for-agent\`를 붙인다."
    echo "#$n: $kind send-back $count of $limit, handed to a human"
    next_ticket
  else
    add_label "$n" ready-for-agent
    next_ticket --first "$n"
    echo "#$n: $kind send-back $count of $limit, back to ready-for-agent (dispatch-next.sh tries it first)"
  fi
}

# unmark_checked <PR>: the PR stays open on a conflict send-back, but no Verify may take it before
# the Implementer resolved it (next-verify picks open PRs with `<!-- factory-checked `): turn its
# checked markers into `<!-- factory-stale-checked `. The Implementer appends a new one.
unmark_checked() {
  local f
  f=$(mktemp)
  if gh api "repos/$REPO/pulls/$1" | j -r '.body // ""' \
      | sed 's/<!-- factory-checked /<!-- factory-stale-checked /g' > "$f"; then
    gh api -X PATCH "repos/$REPO/pulls/$1" -F "body=@$f" >/dev/null \
      || echo "::warning::could not unmark PR #$1 as checked"
  else
    echo "::warning::could not read PR #$1"
  fi
  rm -f "$f"
}

# --- conflict-pr ---------------------------------------------------------------------------------

# The Implementer's guard asks this: when the ticket's last send-back was a conflict and its
# PR is still open, print that PR; the run then merges main into the PR's branch and resolves
# instead of implementing the ticket again.
conflict_pr() {
  local n=$1 last pr state
  last=$(sendbacks "$n" | tail -n 1)
  [ -n "$last" ] || return 0
  [ "$(printf '%s' "$last" | j -r .kind)" = conflict ] || return 0
  pr=$(printf '%s' "$last" | j -r '.pr // empty')
  [ -n "$pr" ] || return 0
  state=$(gh api "repos/$REPO/pulls/$pr" 2>/dev/null | j -r '.state // empty')
  if [ "$state" = open ]; then echo "$pr"; fi
  return 0
}

# --- pass ----------------------------------------------------------------------------------------

pass() {
  local n=$1 pr=$2 report=${3:-} branch attempt merged=false
  branch=$(pr_branch "$pr")
  for attempt in 1 2 3 4; do
    if gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash >/dev/null; then
      merged=true; break
    fi
    echo "::notice::merge attempt $attempt of PR #$pr failed; GitHub may still be computing mergeability"
    sleep "${FACTORY_MERGE_WAIT:-15}"
  done
  if ! $merged; then
    echo "::error::could not merge PR #$pr"
    return 1
  fi
  delete_branch "$branch"
  prune_runs "$branch"
  # The PR's `사람 확인` items go on the spec's check issue; the spec stays open until they are checked
  # (human-check.sh, #167). Failing to stack only warns: the merge is done.
  bash "$here/human-check.sh" stack "$n" "$pr" || echo "::warning::could not stack the 사람 확인 items of PR #$pr"
  if [ -n "$report" ] && [ -s "$report" ]; then
    gh api "repos/$REPO/issues/$pr/comments" -f "body=Verify$(run_link): 통과

$(cat "$report")" >/dev/null || true
  fi
  # A GITHUB_TOKEN merge does not reliably close the ticket via `Closes #N`, and fires no
  # `issues: closed` or push event: close it, run main's release (check + image → production) and move the chain on here.
  comment "$n" "Merged in PR #$pr$(run_link)" || true
  gh api -X PATCH "repos/$REPO/issues/$n" -f state=closed -f state_reason=completed >/dev/null \
    || echo "::warning::could not close #$n"
  remove_label "$n" in-progress
  dispatch release.yml || echo "::warning::could not dispatch release.yml"
  next_ticket
}

# --- next-verify ---------------------------------------------------------------------------------

# Verify is serial (one concurrency group), and a group keeps one pending run: a newer pending run
# cancels the older one without a trace. Two Implementer tracks that hand over while Verify runs
# lose one hand-over that way. Each Verify run therefore ends here: when no other Verify run
# is going, start one for the oldest PR still waiting (open, `Closes #N` and the Implementer's
# `<!-- factory-checked ` marker in its body, ticket #N open and `in-progress`, no Verify run going
# for #N), other than <skip> (the PR this run was about, e.g. one it was cancelled on).
next_verify() {
  local skip=${1:-0} others waiting p n
  others=$(gh run list --repo "$REPO" --workflow factory-verify.yml --limit 50 \
    --json databaseId,status,displayTitle \
    --jq "[.[] | select(.status != \"completed\" and .databaseId != ${GITHUB_RUN_ID:-0})] | length" | tr -d '\r') \
    || { echo "::warning::could not list the Verify runs"; return 0; }
  if [ "${others:-0}" -gt 0 ]; then
    echo "::notice::$others other Verify run(s) going; they start the next one"
    return 0
  fi
  waiting=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -r --argjson skip "$skip" '[.[] | select(.number != $skip)
        | (.body // "") as $b | select($b | contains("<!-- factory-checked "))
        | ($b | capture("Closes #(?<n>[0-9]+)").n // empty) as $n | "\(.number) \($n)"] | sort_by(split(" ")[0] | tonumber) | .[]') \
    || { echo "::warning::could not list the open PRs"; return 0; }
  while read -r p n; do
    [ -n "${n:-}" ] || continue
    read -r state progress < <(gh api "repos/$REPO/issues/$n" \
      | j -r '[.state, (any(.labels[]; .name == "in-progress") | tostring)] | @tsv')
    [ "${state:-}" = open ] && [ "${progress:-}" = true ] || continue
    echo "PR #$p of #$n waits for Verify"
    gh workflow run factory-verify.yml --repo "$REPO" -f issue="$n" -f pr="$p" \
      || echo "::warning::could not dispatch Verify for PR #$p"
    return 0
  done <<< "$waiting"
  echo "no PR waits for Verify"
}

case "${1:-}" in
  mech) [ $# -eq 3 ] || usage; mech "$2" "$3" ;;
  sendback) [ $# -eq 4 ] || [ $# -eq 5 ] || usage; : "${REPO:?REPO is not set}"; sendback "$2" "$3" "$4" "${5:-acceptance}" ;;
  conflict-pr) [ $# -eq 2 ] || usage; : "${REPO:?REPO is not set}"; conflict_pr "$2" ;;
  pass) [ $# -ge 3 ] || usage; : "${REPO:?REPO is not set}"; pass "$2" "$3" "${4:-}" ;;
  next-verify) [ $# -le 2 ] || usage; : "${REPO:?REPO is not set}"; next_verify "${2:-0}" ;;
  *) usage ;;
esac
