#!/usr/bin/env bash
# Records a failed Implementer run on its ticket (factory-implementer.yml, "Record failure"; #410).
#
#   record-failure.sh <ticket> <code|infra> <run url> [<run started at>]
#
# The fourth argument (ISO 8601 UTC, the run's start) says the run made no commits (#414). Then a
# comment on the ticket made since that time, not a factory marker (a body starting with `<!--`), is
# the agent saying why it stopped without the blocked marker (implementer.md §4: a workflow file, a
# decision it cannot make): the ticket goes to a person at once with that comment as the reason, and
# no failure is counted. Without such a comment the failure is counted as below.
# A ticket whose run left a comment starting with `<!-- factory-implementer-blocked -->` after the last
# `<!-- factory-reset -->` (implementer.md §4: the agent cannot go on without a person) goes to a person
# at once through hand-to-human.sh, with that comment as the reason; no failure is counted.
# Otherwise the script leaves the failure marker (`<!-- factory-implementer-failed -->` for a code
# failure, limit 2; `<!-- factory-implementer-infra-failed -->` for anything else, limit 3), counts the
# markers after the last reset, takes `in-progress` off, and either puts `ready-for-agent` back or, at
# the limit, hands the ticket to a person through hand-to-human.sh.
# Environment: REPO, GH_TOKEN; FAILURE_REASON (optional): a line added to the failure comment, e.g.
# merge-check.sh's 「충돌을 풀지 않고 끝남」 (#434).
set -u
: "${REPO:?REPO is not set}"
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo 'usage: record-failure.sh <ticket> <code|infra> <run url> [<run started at>]' >&2; exit 2; }
[ $# -eq 3 ] || [ $# -eq 4 ] || usage
n=$1 kind=$2 url=$3 started=${4:-}
case "$kind" in
  code) marker='<!-- factory-implementer-failed -->' limit=2 what=code ;;
  infra) marker='<!-- factory-implementer-infra-failed -->' limit=3 what=infrastructure ;;
  *) usage ;;
esac
BLOCKED='<!-- factory-implementer-blocked -->'
# A comment by a bot: a GitHub App or github-actions[bot] (only an App installed on the repository can
# comment as one).
BOT='def bot: .user.type == "Bot" or (.user.login // "" | endswith("[bot]"));'

# since_reset: the bodies of the ticket's comments after the last reset comment that a bot wrote (#492:
# the agent and the workflow comment as a bot; anyone can comment on a public repository), as a JSON array.
since_reset() {
  gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    | jq -s "$BOT"' [.[][]] | (map(.body | startswith("<!-- factory-reset -->")) | rindex(true)) as $r
        | [.[(if $r == null then 0 else $r + 1 end):][] | select(bot) | .body]' | tr -d '\r'
}

bodies=$(since_reset) || { echo "::warning::record-failure: could not read the comments of #$n"; bodies='[]'; }
blocked=$(printf '%s' "$bodies" | jq -r --arg b "$BLOCKED" '[.[] | select(startswith($b))] | last // empty' | tr -d '\r')
if [ -n "$blocked" ]; then
  gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
  bash "$here/hand-to-human.sh" "$n" agent-blocked "Implementer가 막힘을 알렸다($url). 사람이 아래를 정한 뒤 티켓을 공장에 돌려준다.

${blocked#"$BLOCKED"}"
  exit $?
fi

if [ -n "$started" ]; then
  said=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    | jq -rs --arg t "$started" "$BOT"' [.[][] | select(.created_at >= $t and bot and (.body | startswith("<!--") | not)) | .body] | last // empty' \
    | tr -d '\r') || said=
  if [ -n "$said" ]; then
    gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
    bash "$here/hand-to-human.sh" "$n" agent-blocked "Implementer가 커밋 없이 멈추며 까닭을 남겼다($url). 사람이 아래를 정한 뒤 티켓을 공장에 돌려준다.

$said"
    exit $?
  fi
fi

gh api "repos/$REPO/issues/$n/comments" -f "body=$marker
Implementer run failed ($what): $url${FAILURE_REASON:+

$FAILURE_REASON}" > /dev/null \
  || echo "::warning::record-failure: could not comment on #$n"
fails=$(since_reset | jq --arg m "$marker" '[.[] | select(contains($m))] | length' | tr -d '\r') || fails=1
gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
if [ "${fails:-0}" -ge "$limit" ]; then
  # The code of the hand-over (#437): the last failure ended on a conflict merge-check.sh found unresolved
  # (the factory's own merge in Finish merge / Require main merged ran first, #434) → conflict.
  case "${FAILURE_REASON:-}" in 충돌을\ 풀지\ 않고\ 끝남*) code=conflict ;; *) code=attempts-exhausted ;; esac
  bash "$here/hand-to-human.sh" "$n" "$code" "Implementer가 ${fails}번 실패했다($what, 한도 ${limit}번, 마지막 run: $url). 공장은 이 티켓을 더 돌리지 않는다: 사람이 실패 까닭을 보고 고친 뒤 \`ready-for-human\`을 떼고 \`ready-for-agent\`를 붙이며 \`<!-- factory-reset -->\` 댓글을 남긴다."
  exit $?
fi
gh api "repos/$REPO/issues/$n/labels" -f "labels[]=ready-for-agent" > /dev/null \
  || { echo "::warning::record-failure: could not put ready-for-agent back on #$n"; exit 1; }
echo "#$n: $what failure $fails of $limit, back in the queue"
