#!/usr/bin/env bash
# The spec's hand-check list (#167). Verify judges a criterion CI cannot see as met when the PR body
# lists it under `사람 확인`; this keeps those items until a person has checked them, and the spec
# stays open until then.
#
#   human-check.sh stack <ticket> <PR>   after Verify merged <PR> of <ticket> (verify.sh pass): append the
#                                        items of the PR body's `사람 확인` section to the spec's check issue
#                                        as `- [ ] <item> (PR #<PR>)` lines. The check issue is the open
#                                        issue labelled `human-check` whose body has
#                                        `<!-- factory-human-check-of <spec> -->` (title
#                                        「사람 확인: spec #<spec>」); made when there is none. A PR already
#                                        on it (`(PR #<PR>)`) is not stacked again. No items, or a ticket
#                                        without a parent spec (ledger.sh parent-of): nothing.
#                                        The check issue is never a sub-issue of the spec and has no
#                                        `## Parent` section, so dispatch-next.sh and the ledger never take it
#                                        for a ticket.
#   human-check.sh gate <spec>           may dispatch-next.sh close <spec>, whose tickets are all merged?
#                                        Exit 0 when no open check issue of the spec has an unchecked
#                                        `- [ ]` line (none at all, all checked, or closed). Exit 1 otherwise,
#                                        and when the check issues could not be read; the first time it
#                                        waits for a check issue it comments `<!-- factory-human-check <spec> -->`
#                                        on it (again, with only the new items, when unchecked items of PRs the earlier markers did not list are stacked later; #170), which bridge.sh mails to the boss.
#
# The items of `사람 확인`: from a heading line (`#`…) containing 사람 확인 to the next heading, every list
# item (`-`, `*`, `+`, `1.`, `1)`, an existing `[ ]`/`[x]` dropped) with its indented continuation lines
# joined, and every other non-empty line as an item of its own. An item that starts with 없음 or None is
# no item.
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN, RUN_URL (optional). Needs bash, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
: "${REPO:?REPO is not set}"
LABEL=human-check

j() { jq "$@" | tr -d '\r'; }

usage() { echo "usage: human-check.sh stack <ticket> <PR> | gate <spec>" >&2; exit 2; }

# items: the `사람 확인` items of a PR body on stdin, one per line.
items() {
  tr -d '\r' | awk '
    function flush() { if (item != "" && item !~ /^(없음|None|none)/) print item; item = "" }
    /^#+[[:space:]]/ { flush(); ins = ($0 ~ /사람 확인/); next }
    !ins { next }
    /^[[:space:]]*$/ { flush(); next }
    /^([-*+]|[0-9]+[.)])[[:space:]]/ {
      flush(); item = $0
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", item); sub(/^\[[ xX]\][[:space:]]*/, "", item)
      next
    }
    /^[[:space:]]/ && item != "" { t = $0; sub(/^[[:space:]]+/, "", t); item = item " " t; next }
    { flush(); item = $0; sub(/^[[:space:]]+/, "", item) }
    END { flush() }'
}

# check_issues <spec>: the open check issues of <spec> as JSON [{number, body}], oldest first.
check_issues() {
  gh api "repos/$REPO/issues?labels=$LABEL&state=open&per_page=100" --paginate \
    | j -s --arg m "<!-- factory-human-check-of $1 -->" \
      '[add // [] | .[] | select(.pull_request | not) | select((.body // "") | contains($m)) | {number, body}]
       | sort_by(.number)'
}

stack() {
  local n=$1 pr=$2 list spec issues issue body lines f
  list=$(gh api "repos/$REPO/pulls/$pr" | j -r '.body // ""' | items) \
    || { echo "::warning::human-check: could not read PR #$pr"; return 1; }
  [ -n "$list" ] || { echo "PR #$pr lists no 사람 확인 item"; return 0; }
  spec=$(REPO=$REPO bash "$here/ledger.sh" parent-of "$n" 2>/dev/null | tr -d '\r')
  if [ -z "$spec" ] || [ "$spec" = "$n" ]; then
    echo "::notice::#$n has no parent spec; its 사람 확인 items are not stacked"
    return 0
  fi
  lines=$(printf '%s\n' "$list" | sed "s/^/- [ ] /; s/\$/ (PR #$pr)/")
  issues=$(check_issues "$spec") || { echo "::warning::human-check: could not list the check issues"; return 1; }
  issue=$(printf '%s' "$issues" | j -r '.[0].number // empty')
  f=$(mktemp)
  if [ -z "$issue" ]; then
    printf '<!-- factory-human-check-of %s -->\nspec: #%s\n\n미체크 항목이 남아 있으면 공장이 spec #%s 를 닫지 않고 다음 spec 으로 넘어가지 않는다.\n\n%s\n' \
      "$spec" "$spec" "$spec" "$lines" > "$f"
    issue=$(gh api "repos/$REPO/issues" -f "title=사람 확인: spec #$spec" -F "body=@$f" -f "labels[]=$LABEL" \
      | j -r '.number // empty')
    rm -f "$f"
    [ -n "$issue" ] || { echo "::warning::human-check: could not open the check issue of spec #$spec"; return 1; }
    echo "stacked PR #$pr on the new check issue #$issue of spec #$spec"
    return 0
  fi
  body=$(printf '%s' "$issues" | j -r '.[0].body // ""')
  case "$body" in
    *"(PR #$pr)"*) rm -f "$f"; echo "PR #$pr is already on check issue #$issue"; return 0 ;;
  esac
  printf '%s\n%s\n' "${body%$'\n'}" "$lines" > "$f"
  if ! gh api -X PATCH "repos/$REPO/issues/$issue" -F "body=@$f" > /dev/null; then
    rm -f "$f"; echo "::warning::human-check: could not add PR #$pr to check issue #$issue"; return 1
  fi
  rm -f "$f"
  echo "stacked PR #$pr on check issue #$issue of spec #$spec"
}

gate() {
  local spec=$1 issues waiting n left marker prs told fresh new text p
  issues=$(check_issues "$spec") || { echo "could not read the check issues of spec #$spec"; return 1; }
  waiting=$(printf '%s' "$issues" | j -r '.[] | "\(.number) \([(.body // "") | split("\n")[]
    | select(test("^\\s*[-*+] \\[ \\]"))] | length)" | select(endswith(" 0") | not)')
  [ -n "$waiting" ] || return 0
  marker="<!-- factory-human-check $spec -->"
  while read -r n left; do
    echo "check issue #$n of spec #$spec has $left unchecked item(s)"
    # PRs of the unchecked items, and the PRs the markers already left on this issue told about
    # (second line `<!-- prs 41 42 -->`; an older marker without it told about none).
    prs=$(printf '%s' "$issues" | j -r --argjson n "$n" '.[] | select(.number == $n) | (.body // "") | split("\n")[]
      | select(test("^\\s*[-*+] \\[ \\]")) | (capture("\\(PR #(?<p>[0-9]+)\\)\\s*$") | .p) // empty' | sort -un)
    told=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate --jq '.[].body
      | select(split("\n")[0] == "'"$marker"'") | "M " + ((split("\n")[1] // "") | sub("^<!-- prs ?"; "") | sub(" ?-->$"; ""))') \
      || { echo "::warning::human-check: could not read the comments of #$n"; continue; }
    told=$(printf '%s\n' "$told" | tr -d '\r')
    fresh=
    for p in $prs; do
      printf '%s\n' "$told" | grep -qE "^M (.* )?$p( .*)?$" || fresh="$fresh $p"
    done
    # nothing new since the last marker (a marker was left and no unchecked PR is missing from it)
    if [ -n "$told" ] && [ -z "$fresh" ]; then continue; fi
    if [ -z "$told" ]; then
      text="spec #$spec 의 티켓이 모두 병합됐다. 이 이슈의 사람 확인 $left 건이 미체크라 공장이 spec #$spec 을 닫지 않고 기다린다. 확인한 항목을 체크하고(문제는 새 이슈로) 모두 체크하거나 이 이슈를 닫으면 다음 dispatch 때 spec 이 닫힌다."
      fresh=$(printf ' %s' $prs)
    else
      new=$(printf '%s' "$issues" | j -r --argjson n "$n" --arg f "$fresh " '.[] | select(.number == $n) | (.body // "") | split("\n")[]
        | select(test("^\\s*[-*+] \\[ \\]")) | select((capture("\\(PR #(?<p>[0-9]+)\\)\\s*$").p) as $p | $f | contains(" " + $p + " "))')
      text="앞서 알린 뒤 사람 확인 항목이 새로 쌓였다. 공장은 여전히 spec #$spec 을 닫지 않고 기다린다. 새 미체크 항목:

$new"
    fi
    gh api "repos/$REPO/issues/$n/comments" -f "body=$marker
<!-- prs${fresh} -->
$text${RUN_URL:+ ($RUN_URL)}" > /dev/null \
      || echo "::warning::human-check: could not comment on #$n"
  done <<< "$waiting"
  return 1
}

case "${1:-}" in
  stack) [ $# -eq 3 ] || usage; stack "$2" "$3" ;;
  gate) [ $# -eq 2 ] || usage; gate "$2" ;;
  *) usage ;;
esac
