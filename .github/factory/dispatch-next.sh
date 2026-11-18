#!/usr/bin/env bash
# Keeps the factory going (factory-implementer.yml: the end of an implement run, the frontier and
# approval jobs and the daily schedule after KST midnight; verify.sh after a merge or a send-back;
# odin.sh after approving a spec's tickets; resume.sh).
#
#   dispatch-next.sh [--tickets-only] [--candidates "N M …"] [--first N]
#
# Tracks: the Implementer runs up to FACTORY_TRACKS tickets at once (the repository variable of
# the same name; empty or not a positive number: 2), one per track. Track T is the concurrency group
# `factory-impl-T` of factory-implementer.yml, and a group holds one running and one pending run and
# silently cancels any other pending run, so this script dispatches only into empty tracks. A track is
# busy while a factory-implementer workflow_dispatch run that is not completed holds it (other than
# the run calling this script, GITHUB_RUN_ID): its title is `implement #N (track T)`; a run without
# that title (dispatched before tracks existed) holds track 1. Runs, not `in-progress` tickets, count:
# a ticket stays `in-progress` while it waits for Verify, which is serial and separate, and an
# `in-progress` label left by a broken run would hold a track for ever.
#
# 1. Fills every empty track, lowest track first, with the lowest-numbered open `ready-for-agent`
#    ticket (not a spec: no `spec` label and no sub-issues; not `local`) with no open blocker, no running implement run, and a budget guard (ledger.sh guard) that
#    says go (--first N is tried before the others: the ticket Verify just sent back). A ticket whose
#    spec is paused or needs a decision is passed over; when the daily budget is spent nothing starts
#    (the schedule resumes after KST midnight). The tickets are those of the label search plus
#    --candidates: the label search (`gh issue list`, a search index) can miss a label added a moment
#    ago, so a caller that has just labelled tickets names them. Each ticket's state, label and
#    blockers are read from the issue API, which is up to date. Without --candidates an empty search
#    is asked once more after FACTORY_LIST_RETRY_WAIT seconds (default 10).
#    No double dispatch: after each dispatch this script waits (up to FACTORY_DISPATCH_SEEN_WAIT
#    seconds, default 60) until the new run is listed, so the next call sees the ticket and its track
#    busy. Two calls at the same moment can still both pick a ticket; the implement job's per-ticket
#    concurrency group (`factory-ticket-N`) then holds the second run until the first claimed the
#    ticket, and its guard finds the ticket no longer `ready-for-agent` and stops.
# 2. With an empty track left (and, with one track, without --tickets-only): closes finished specs
#    (not while its check issue has unchecked `사람 확인` items, human-check.sh gate: such a spec is
#    running, so with FACTORY_TRACKS=1 the next spec waits for it),
#    resumes a spec whose decompose stopped (no sub-issues and no decompose run going), and when
#    fewer specs are running than there are tracks, labels the next spec of FACTORY_SPEC_QUEUE and
#    dispatches its decompose (in queue order), one spec per call. A spec is
#    running while it has no tickets yet or an open ticket labelled `in-progress` or
#    `ready-for-agent`; such a ticket outside every open spec counts as a spec of its own. With one
#    track this is the earlier rule: nothing in progress or waiting. An empty queue never moves on to
#    another spec (ADR-0001: the trial runs one labelled spec only).
# 3. Tells the mail bridge (bridge.sh) through a marker comment on the ledger issue, once per marker
#    (a comment starting with the same marker line is not left again; failing to comment only warns):
#      <!-- factory-queue-empty S -->  the spec S just labelled was the last open unlabelled spec of
#                                      the queue (a warning ahead: S is still running)
#      <!-- factory-idle Q -->         every spec of the queue is labelled; Q is the queue with its
#                                      numbers joined by `-` (`none` when empty), so a new queue
#                                      is told again
#
# Environment: REPO, GH_TOKEN, FACTORY_TRACKS, FACTORY_SPEC_QUEUE (spec numbers in order; the
# repository variable of the same name), FACTORY_LIST_RETRY_WAIT, FACTORY_DISPATCH_SEEN_WAIT,
# GITHUB_RUN_ID, and the budget variables of ledger.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
: "${REPO:?REPO is not set}"
usage() { echo 'usage: dispatch-next.sh [--tickets-only] [--candidates "N M …"] [--first N]' >&2; exit 2; }
tickets_only=false
candidates=
first=
while [ $# -gt 0 ]; do
  case "$1" in
    --tickets-only) tickets_only=true; shift ;;
    --candidates) [ $# -ge 2 ] || usage; candidates=$2; shift 2 ;;
    --first) [ $# -ge 2 ] || usage; first=$2; shift 2 ;;
    *) usage ;;
  esac
done
for n in $candidates $first; do
  case "$n" in *[!0-9]*) usage ;; esac
done

tracks=${FACTORY_TRACKS:-}
case "$tracks" in
  '' ) tracks=2 ;;
  *[!0-9]* | 0 | 00*) echo "::warning::FACTORY_TRACKS=$tracks is not a positive number; using 2"; tracks=2 ;;
esac
# With one track, --tickets-only keeps its earlier meaning; with more, every call fills every track.
[ "$tracks" -gt 1 ] && tickets_only=false

# go <issue>: run the budget guard; prints its reason and succeeds when it may start.
go() {
  local out; out=$(mktemp)
  GITHUB_OUTPUT=$out bash "$here/ledger.sh" guard "$1" > /dev/null
  local g r
  g=$(sed -n 's/^go=//p' "$out" | tail -n 1)
  r=$(sed -n 's/^reason=//p' "$out" | tail -n 1)
  rm -f "$out"
  echo "$r"
  [ "$g" = true ]
}

# notify <marker line> <text>: leaves "<marker>\n<text>" on the ledger issue (the open issue labelled
# `factory-ledger`, as ledger.sh finds it) unless a comment there already starts with that marker line.
# bridge.sh mails it. Never fails: a missing ledger or a failed call only warns.
notify() {
  local marker=$1 text=$2 ledger firsts
  ledger=$(gh api "repos/$REPO/issues?labels=factory-ledger&state=open&per_page=100" \
    --jq '[.[] | select(.pull_request | not)] | sort_by(.number) | .[0].number // empty') \
    || { echo "::warning::dispatch-next: could not find the ledger issue for $marker"; return 0; }
  ledger=$(printf '%s' "$ledger" | tr -d '\r')
  if [ -z "$ledger" ]; then
    echo "::warning::dispatch-next: no open factory-ledger issue; $marker not left"
    return 0
  fi
  firsts=$(gh api "repos/$REPO/issues/$ledger/comments?per_page=100" --paginate \
    --jq '.[].body | split("\n")[0]') \
    || { echo "::warning::dispatch-next: could not read the ledger #$ledger; $marker not left"; return 0; }
  if printf '%s\n' "$firsts" | tr -d '\r' | grep -qxF -- "$marker"; then
    return 0
  fi
  gh api "repos/$REPO/issues/$ledger/comments" -f "body=$marker
$text" > /dev/null \
    || echo "::warning::dispatch-next: could not leave $marker on the ledger #$ledger"
  return 0
}

# implement_runs: "<ticket> <track> <run id>" per factory-implementer workflow_dispatch run that is not
# completed, other than this run. Ticket 0 and track 1 for a run without the track title.
implement_runs() {
  gh run list --repo "$REPO" --workflow factory-implementer.yml --limit 100 \
    --json databaseId,status,event,displayTitle \
    --jq '.[] | select(.status != "completed" and .event == "workflow_dispatch"
      and .databaseId != '"${GITHUB_RUN_ID:-0}"')
      | .databaseId as $id
      | ((.displayTitle | capture("^implement #(?<n>[0-9]+) \\(track (?<t>[0-9]+)\\)")) // {n: "0", t: "1"})
      | "\(.n) \(.t) \($id)"' | tr -d '\r'
}

runs=$(implement_runs) || { echo "::error::could not list the factory-implementer runs"; exit 1; }
busy_tickets=" $(printf '%s\n' "$runs" | awk 'NF { print $1 }' | tr '\n' ' ')"
busy_tracks=" $(printf '%s\n' "$runs" | awk 'NF { print $2 }' | tr '\n' ' ')"
free=
for t in $(seq 1 "$tracks"); do
  case "$busy_tracks" in *" $t "*) ;; *) free="$free $t" ;; esac
done
set -- $free
echo "tracks: $tracks, empty:${free:- none}"
if [ $# -eq 0 ]; then
  echo "::notice::every track is busy; nothing to dispatch"
  exit 0
fi

# seen <ticket> <track> <after run id>: a run of that title newer than <after> is listed.
seen() {
  gh run list --repo "$REPO" --workflow factory-implementer.yml --limit 20 --json databaseId,displayTitle \
    --jq "any(.[]; .databaseId > $3 and .displayTitle == \"implement #$1 (track $2)\")" | tr -d '\r' \
    | grep -qx true
}

# dispatch <ticket> <track>: dispatch the Implementer and wait until the run is listed.
dispatch() {
  local n=$1 t=$2 last waited=0 limit=${FACTORY_DISPATCH_SEEN_WAIT:-60}
  last=$(gh run list --repo "$REPO" --workflow factory-implementer.yml --limit 1 --json databaseId \
    --jq '.[0].databaseId // 0' | tr -d '\r')
  echo "dispatch #$n on track $t"
  gh workflow run factory-implementer.yml --repo "$REPO" -f track="$t" -f issue="$n" || {
    echo "::error::could not dispatch #$n"; return 1; }
  until seen "$n" "$t" "${last:-0}"; do
    if [ "$waited" -ge "$limit" ]; then
      echo "::warning::the run of #$n on track $t is not listed after ${limit}s"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
}

# listed: open `ready-for-agent` issues by the label search, ascending.
listed() {
  gh issue list --repo "$REPO" --state open --label ready-for-agent --limit 200 --json number \
    --jq 'sort_by(.number) | .[].number'
}
found=$(listed)
if [ -z "$found" ] && [ -z "$candidates" ] && [ -z "$first" ]; then
  wait=${FACTORY_LIST_RETRY_WAIT:-10}
  echo "::notice::the ready-for-agent search is empty; asking again in ${wait}s (the search index may lag)"
  sleep "$wait"
  found=$(listed)
fi

for n in $first $(printf '%s\n' $found $candidates | sort -n -u | grep -vx "${first:-x}"); do
  [ $# -gt 0 ] || break
  case "$busy_tickets" in *" $n "*) echo "::notice::#$n already has an implement run"; continue ;; esac
  read -r state ready open isspec islocal subs < <(gh api "repos/$REPO/issues/$n" --jq '[.state,
    (any(.labels[]; .name == "ready-for-agent") | tostring),
    (.issue_dependencies_summary.blocked_by // 0 | tostring),
    (any(.labels[]; .name == "spec") | tostring),
    (any(.labels[]; .name == "local") | tostring),
    (.sub_issues_summary.total // 0 | tostring)] | @tsv')
  [ "${state:-}" = open ] && [ "${ready:-}" = true ] || continue
  # A spec (label `spec`) or an issue with sub-issues is a parent, not a ticket.
  # A `local` ticket (workflow files) is for a local worker, never the factory.
  if [ "${islocal:-false}" = true ]; then echo "::notice::#$n is local; not for the factory"; continue; fi
  if [ "${isspec:-false}" = true ] || [ "${subs:-0}" -gt 0 ]; then
    echo "::notice::#$n is a spec or has sub-issues; not a ticket"
    continue
  fi
  [ "${open:-1}" -eq 0 ] || continue
  if reason=$(go "$n"); then
    dispatch "$n" "$1" || exit 1
    busy_tickets="$busy_tickets$n "
    shift
    continue
  fi
  if [ "$reason" = daily ]; then
    echo "::notice::the daily budget is spent; the schedule resumes after KST midnight"
    exit 0
  fi
  echo "::notice::#$n does not start ($reason); trying the next ticket"
done
if [ $# -eq 0 ]; then
  echo "every track is busy now"
  exit 0
fi
echo "::notice::no unblocked approved ticket may start for track(s) $*"
$tickets_only && exit 0

# Specs. Count the running ones (see 2. above); close finished ones; resume a stopped decompose.
specs=$(gh issue list --repo "$REPO" --state open --label spec --json number --jq '.[].number' | tr -d '\r')
active=$( { gh issue list --repo "$REPO" --state open --label in-progress --json number --jq '.[].number'
  gh issue list --repo "$REPO" --state open --label ready-for-agent --json number --jq '.[].number'; } \
  | tr -d '\r' | sort -n -u)
running=0
covered=" "
for s in $specs; do
  read -r total done < <(gh api "repos/$REPO/issues/$s" --jq '"\(.sub_issues_summary.total // 0) \(.sub_issues_summary.completed // 0)"')
  if [ "$total" -eq 0 ]; then
    running=$((running + 1))
    going=$(gh run list --repo "$REPO" --workflow factory-decompose.yml --limit 20 --json status --jq '[.[] | select(.status != "completed")] | length')
    if [ "$going" -gt 0 ]; then
      echo "::notice::spec #$s is still being decomposed"
      continue
    fi
    # Its decompose stopped (budget, decision) or failed: start it again if the guard allows.
    if reason=$(go "$s"); then
      echo "decompose #$s again"
      gh workflow run factory-decompose.yml --repo "$REPO" -f issue="$s"
    else
      echo "::notice::spec #$s has no tickets and may not be decomposed now ($reason)"
    fi
    continue
  fi
  if [ "$total" -eq "$done" ]; then
    # Unchecked `사람 확인` items hold the spec open, and it counts as running, so the next spec waits
    # (human-check.sh gate, #167).
    if ! bash "$here/human-check.sh" gate "$s"; then
      echo "::notice::spec #$s waits for its 사람 확인 items"
      running=$((running + 1))
      continue
    fi
    gh issue close "$s" --repo "$REPO" --reason completed --comment "All $total tickets merged."
    continue
  fi
  subs=" $(gh api "repos/$REPO/issues/$s/sub_issues?per_page=100" --paginate --jq '.[].number' | tr -d '\r' | tr '\n' ' ')"
  covered="$covered${subs# }"
  for n in $active; do
    case "$subs" in *" $n "*) running=$((running + 1)); break ;; esac
  done
done
for n in $active; do
  case "$covered" in *" $n "*) ;; *) running=$((running + 1)) ;; esac
done
if [ "$running" -ge "$tracks" ]; then
  echo "::notice::$running spec(s) running on $tracks track(s); not moving to the next spec yet"
  exit 0
fi
# The queue's open specs without the `spec` label, in queue order.
pending=
for s in ${FACTORY_SPEC_QUEUE:-}; do
  read -r state labels < <(gh issue view "$s" --repo "$REPO" --json state,labels --jq '[.state, ([.labels[].name] | join(","))] | @tsv')
  [ "$state" = OPEN ] || continue
  case ",$labels," in *,spec,*) continue;; esac
  pending="$pending $s"
done
set -- $pending
if [ $# -gt 0 ]; then
  s=$1
  if ! reason=$(go "$s"); then
    echo "::notice::next spec #$s may not start ($reason)"
    exit 0
  fi
  echo "next spec: #$s"
  gh issue edit "$s" --repo "$REPO" --add-label spec
  gh workflow run factory-decompose.yml --repo "$REPO" -f issue="$s"
  if [ $# -eq 1 ]; then
    notify "<!-- factory-queue-empty $s -->" "spec 큐 바닥남: #$s가 FACTORY_SPEC_QUEUE에 남은 마지막 spec이다. 공장은 #$s를 돌리는 중이고, 이것이 끝나면 할 일이 없다. 다음 spec을 FACTORY_SPEC_QUEUE에 넣는다."
  fi
  exit 0
fi
[ "$running" -gt 0 ] && exit 0
echo "::notice::every spec in the queue is labelled; the factory is idle"
q=$(printf '%s' "${FACTORY_SPEC_QUEUE:-}" | tr -s ' \t\r\n,' '-' | sed 's/^-//; s/-$//')
notify "<!-- factory-idle ${q:-none} -->" "공장 idle: FACTORY_SPEC_QUEUE(${FACTORY_SPEC_QUEUE:-비어 있음})의 spec이 모두 라벨을 받아 띄울 spec이 없다. FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다."
exit 0
