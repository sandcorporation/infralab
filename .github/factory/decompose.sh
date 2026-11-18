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
#   decompose.sh create-tickets <S> <tickets.json>
#                                   publish the tickets of spec #S in one call (#185): per ticket create the
#                                   issue (adds "## Parent", "## Blocked by" with the real numbers, the local
#                                   marker and `<!-- factory-ticket spec=S -->` to the body), make it a
#                                   sub-issue of #S, add native blocked-by edges, the `model:*` label, and for
#                                   a local ticket `local` and local-ticket.sh (→ `ready-for-human`). Prints
#                                   `#<n> <key> <title>` per ticket. Idempotent by title + marker: run it again
#                                   after a failure and it finishes the rest without duplicates. File format
#                                   above create_tickets.
#   decompose.sh create-ticket <S> --title T --body-file F [--model sonnet|opus] [--local workflows|claude]
#                                   [--blocked-by N,M]   the same for one ticket; prints its number.
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

# --- publishing tickets (#185) ---------------------------------------------------------------
# One call per spec instead of four or five gh calls per ticket: the Decompose agent's turns no longer
# grow with the number of tickets.

ticket_marker() { echo "<!-- factory-ticket spec=$1 -->"; }

# Number of the open issue with this title that carries the spec's ticket marker, empty when none.
# Fails when the list cannot be read (never guess "none": that would create a duplicate).
find_ticket() { # find_ticket <S> <title>
  local list
  list=$(gh api "repos/$REPO/issues?state=open&per_page=100" --paginate) \
    || { echo "::error::could not list the issues" >&2; return 1; }
  printf '%s' "$list" | j -s -r --arg t "$2" --arg m "$(ticket_marker "$1")" \
      'add // [] | map(select((.pull_request | not) and .title == $t and ((.body // "") | contains($m))))
        | sort_by(.number) | .[0].number // empty'
}

db_id() { gh api "repos/$REPO/issues/$1" | j -r '.id // empty'; }

# Create (or find) one ticket and link it. Prints its number on success; on failure prints the number
# when the issue exists, then returns 1.
# publish_one <S> <title> <body file> <model|""> <local kind|""> <blocker numbers, space-separated>
publish_one() {
  local s=$1 title=$2 bodyf=$3 model=$4 kind=$5 blockers=$6 n body id b bid have l
  n=$(find_ticket "$s" "$title") || return 1
  if [ -z "$n" ]; then
    body=$(cat "$bodyf")
    case "$body" in *"## Parent"*) ;; *) body="## Parent

#$s

$body" ;;
    esac
    case "$body" in *"## Blocked by"*) ;; *)
      if [ -n "$blockers" ]; then
        b=$(for x in $blockers; do printf '#%s, ' "$x"; done); b=${b%, }
      else
        b="None (can start immediately)"
      fi
      body="$body

## Blocked by

$b" ;;
    esac
    case "$kind" in
      workflows) body="$body

workflow 파일 — 로컬 작업자 몫
<!-- factory-touches-workflows -->" ;;
      claude) body="$body

\`.claude/\` 파일 — 로컬 작업자 몫
<!-- factory-touches-claude -->" ;;
    esac
    body="$body

$(ticket_marker "$s")"
    n=$(gh api "repos/$REPO/issues" -f "title=$title" -f "body=$body" | j -r '.number // empty')
    [ -n "$n" ] || { echo "::error::could not create the ticket \"$title\"" >&2; return 1; }
  fi
  echo "$n"
  id=$(db_id "$n")
  [ -n "$id" ] || { echo "::error::could not read #$n" >&2; return 1; }
  if [ "$(gh api "repos/$REPO/issues/$s/sub_issues?per_page=100" --paginate \
      | j -s --argjson n "$n" 'add // [] | any(.number == $n)')" != true ]; then
    gh api -X POST "repos/$REPO/issues/$s/sub_issues" -F "sub_issue_id=$id" > /dev/null \
      || { echo "::error::could not make #$n a sub-issue of #$s" >&2; return 1; }
  fi
  if [ -n "$blockers" ]; then
    have=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by?per_page=100" --paginate) \
      || { echo "::error::could not read the blockers of #$n" >&2; return 1; }
    have=$(printf '%s' "$have" | j -s -r 'add // [] | map(.number) | join(" ")')
    for b in $blockers; do
      case " $have " in *" $b "*) continue ;; esac
      bid=$(db_id "$b")
      [ -n "$bid" ] && gh api -X POST "repos/$REPO/issues/$n/dependencies/blocked_by" -F "issue_id=$bid" > /dev/null \
        || { echo "::error::could not record #$n blocked by #$b" >&2; return 1; }
    done
  fi
  for l in ${model:+model:$model} ${kind:+local}; do
    gh api "repos/$REPO/issues/$n/labels" -f "labels[]=$l" > /dev/null \
      || { echo "::error::could not label #$n $l" >&2; return 1; }
  done
  if [ -n "$kind" ]; then
    env -u GITHUB_OUTPUT bash "$here/local-ticket.sh" "$n" > /dev/null \
      || { echo "::error::local-ticket.sh failed on #$n" >&2; return 1; }
  fi
}

# create_tickets <S> <file>: the file is a JSON array, blockers first:
#   [{"key": "a", "title": "…", "body_file": "path" | "body": "…", "model": "sonnet"|"opus",
#     "local": "workflows"|"claude", "blocked_by": ["<key of an earlier entry>", 123, …]}]
# A string blocker is the key of an earlier entry, a number an existing issue.
# key defaults to the 1-based position; model defaults to sonnet, and a local ticket gets none.
# Prints `#<n> <key> <title>` per ticket. Safe to run again: a ticket with the same title and the spec's
# marker is found, not created twice, and its missing links and labels are added.
create_tickets() {
  local s=$1 file=$2 spec_json count i e key title body_file model kind blockers b n out tmp
  [ -f "$file" ] || { echo "::error::no file $file" >&2; return 2; }
  spec_json=$(j -c 'if type == "array" then . else error("not a JSON array") end
    | to_entries | map(.value + {key: ((.value.key // (.key + 1)) | tostring)})' "$file") \
    || { echo "::error::$file is not a JSON array of tickets" >&2; return 2; }
  # Check the whole file before creating anything.
  if ! e=$(printf '%s' "$spec_json" | j -r '
      . as $all | to_entries[] | .key as $i | .value as $t
      | (if ($t.title // "") == "" then "ticket \($t.key): no title" else empty end),
        (if ($t.body // "") == "" and ($t.body_file // "") == "" then "ticket \($t.key): no body or body_file" else empty end),
        (if ($t.local // null) != null and ($t.local | IN("workflows", "claude") | not) then "ticket \($t.key): local must be workflows or claude" else empty end),
        (if ($t.local // null) == null and (($t.model // "sonnet") | IN("sonnet", "opus") | not) then "ticket \($t.key): model must be sonnet or opus" else empty end),
        (($t.blocked_by // [])[] | if type == "number" then empty
          elif type == "string" and (. as $b | [$all[:$i][].key] | index($b)) != null then empty
          else "ticket \($t.key): blocker \(.) is neither an earlier key (string) nor an issue number (number)" end),
        (if ([$all[:$i][].key] | index($t.key)) != null then "ticket \($t.key): duplicate key" else empty end)') ; then
    echo "::error::could not read $file" >&2; return 2
  fi
  if [ -n "$e" ]; then printf '::error::%s\n' "$e" >&2; return 2; fi
  count=$(printf '%s' "$spec_json" | j 'length')
  tmp=$(mktemp -d)
  declare -A num=()
  out=
  for ((i = 0; i < count; i++)); do
    e=$(printf '%s' "$spec_json" | j -c ".[$i]")
    key=$(printf '%s' "$e" | j -r '.key')
    title=$(printf '%s' "$e" | j -r '.title')
    kind=$(printf '%s' "$e" | j -r '.local // empty')
    model=
    [ -n "$kind" ] || model=$(printf '%s' "$e" | j -r '.model // "sonnet"')
    body_file=$(printf '%s' "$e" | j -r '.body_file // empty')
    if [ -z "$body_file" ]; then
      body_file="$tmp/body-$i"
      printf '%s' "$e" | j -r '.body' > "$body_file"
    elif [ ! -f "$body_file" ]; then
      echo "::error::ticket $key: no file $body_file" >&2
      echo "created so far: ${out:-none}" >&2
      return 1
    fi
    blockers=
    for b in $(printf '%s' "$e" | j -r '(.blocked_by // [])[] | if type == "number" then "n:\(.)" else "k:\(.)" end'); do
      case "$b" in n:*) blockers="$blockers ${b#n:}" ;; *) blockers="$blockers ${num[${b#k:}]}" ;; esac
    done
    blockers=${blockers# }
    n=$(publish_one "$s" "$title" "$body_file" "$model" "$kind" "$blockers")
    if [ $? -ne 0 ]; then
      [ -n "$n" ] && out="$out #$n($key, incomplete)"
      echo "::error::stopped at ticket $key; created so far:${out:- none}. Run the same command again to finish (no duplicates)." >&2
      return 1
    fi
    num[$key]=$n
    out="$out #$n($key)"
    echo "#$n $key $title"
  done
}

# create-ticket <S> --title T --body-file F [--model sonnet|opus] [--local workflows|claude] [--blocked-by 1,2]
create_ticket() {
  local s=$1 title= body_file= model= kind= blocked= f out
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=$2; shift 2 ;;
      --body-file) body_file=$2; shift 2 ;;
      --model) model=$2; shift 2 ;;
      --local) kind=$2; shift 2 ;;
      --blocked-by) blocked=$2; shift 2 ;;
      *) echo "::error::create-ticket: unknown argument $1" >&2; return 2 ;;
    esac
  done
  f=$(mktemp)
  jq -n --arg t "$title" --arg bf "$body_file" --arg m "$model" --arg k "$kind" --arg b "$blocked" \
    '[{title: $t, body_file: $bf} + (if $m != "" then {model: $m} else {} end)
      + (if $k != "" then {local: $k} else {} end)
      + {blocked_by: ($b | split(",") | map(gsub("[ #]"; "")) | map(select(. != "") | tonumber))}]' > "$f" \
    || { echo "::error::create-ticket: --blocked-by takes issue numbers (N,M)" >&2; return 2; }
  out=$(create_tickets "$s" "$f") || return $?
  printf '%s\n' "$out" | sed -n 's/^#\([0-9]*\) .*/\1/p'
}

usage() {
  echo "usage: decompose.sh state <S> | finish <S> <mode> | dispatch-odin <S>" >&2
  echo "       decompose.sh create-tickets <S> <tickets.json>" >&2
  echo "       decompose.sh create-ticket <S> --title T --body-file F [--model sonnet|opus] [--local workflows|claude] [--blocked-by N,M]" >&2
  exit 2
}

: "${REPO:?REPO is not set}"
case "${1:-}" in
  state) [ $# -eq 2 ] || usage; state "$2" ;;
  finish) [ $# -eq 3 ] || usage; finish "$2" "$3" ;;
  dispatch-odin) [ $# -eq 2 ] || usage; dispatch_odin "$2" ;;
  create-tickets) [ $# -eq 3 ] || usage; create_tickets "$2" "$3" ;;
  create-ticket) [ $# -ge 2 ] || usage; shift; create_ticket "$@" ;;
  *) usage ;;
esac
