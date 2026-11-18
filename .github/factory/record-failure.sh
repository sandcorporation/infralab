#!/usr/bin/env bash
# Records a failed Implementer run on its ticket (factory-implementer.yml, "Record failure"; #192).
#
#   record-failure.sh <ticket> <code|infra|nocommit> <run url>
#
# A ticket whose run left a comment starting with `<!-- factory-implementer-blocked -->` after the last
# `<!-- factory-reset -->` (implementer.md §4: the agent cannot go on without a person) goes to a person
# at once through hand-to-human.sh, with that comment as the reason; no failure is counted.
# `nocommit` (the agent made no commit) does the same with the newest comment a bot left on the ticket
# since $RUN_STARTED_AT that is not a factory marker: an agent that stopped and said why without the
# marker line (#212: #194's wrong acceptance test counted as three infrastructure failures). Without
# such a comment (or without RUN_STARTED_AT) `nocommit` is an infrastructure failure.
# Otherwise the script leaves the failure marker (`<!-- factory-implementer-failed -->` for a code
# failure, limit 2; `<!-- factory-implementer-infra-failed -->` for anything else, limit 3), counts the
# markers after the last reset, takes `in-progress` off, and either puts `ready-for-agent` back or, at
# the limit, hands the ticket to a person through hand-to-human.sh.
# Environment: REPO, GH_TOKEN; RUN_STARTED_AT (UTC, `%Y-%m-%dT%H:%M:%SZ`) for nocommit.
set -u
: "${REPO:?REPO is not set}"
here=$(cd "$(dirname "$0")" && pwd)
usage='usage: record-failure.sh <ticket> <code|infra|nocommit> <run url>'
[ $# -eq 3 ] || { echo "$usage" >&2; exit 2; }
n=$1 kind=$2 url=$3
case "$kind" in
  code) marker='<!-- factory-implementer-failed -->' limit=2 what=code ;;
  infra | nocommit) marker='<!-- factory-implementer-infra-failed -->' limit=3 what=infrastructure ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
BLOCKED='<!-- factory-implementer-blocked -->'

# comments_since_reset: the ticket's comments after the last reset comment ({body, created_at, login}),
# as a JSON array.
comments_since_reset() {
  gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    | jq -s '[.[][] | {body, created_at, login: .user.login}]
        | (map(.body | startswith("<!-- factory-reset -->")) | rindex(true)) as $r
        | .[(if $r == null then 0 else $r + 1 end):]' | tr -d '\r'
}
# since_reset: the bodies of those comments.
since_reset() { comments_since_reset | jq '[.[].body]' | tr -d '\r'; }

comments=$(comments_since_reset) || { echo "::warning::record-failure: could not read the comments of #$n"; comments='[]'; }
blocked=$(printf '%s' "$comments" | jq -r --arg b "$BLOCKED" '[.[].body | select(startswith($b))] | last // empty' | tr -d '\r')
if [ -n "$blocked" ]; then
  gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
  bash "$here/hand-to-human.sh" "$n" "Implementer가 막힘을 알렸다($url). 사람이 아래를 정한 뒤 티켓을 공장에 돌려준다.

${blocked#"$BLOCKED"}"
  exit $?
fi
if [ "$kind" = nocommit ] && [ -n "${RUN_STARTED_AT:-}" ]; then
  said=$(printf '%s' "$comments" | jq -r --arg t "$RUN_STARTED_AT" '[.[] | select(.created_at >= $t
      and (.login | endswith("[bot]")) and ((.body | ltrimstr("\n") | startswith("<!--")) | not)) | .body]
    | last // empty' | tr -d '\r')
  if [ -n "$said" ]; then
    gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
    bash "$here/hand-to-human.sh" "$n" "Implementer가 커밋 없이 멈추고 까닭을 남겼다($url). 실패로 세지 않는다: 사람이 아래를 정한 뒤 티켓을 공장에 돌려준다.

$said"
    exit $?
  fi
fi

gh api "repos/$REPO/issues/$n/comments" -f "body=$marker
Implementer run failed ($what): $url" > /dev/null \
  || echo "::warning::record-failure: could not comment on #$n"
fails=$(since_reset | jq --arg m "$marker" '[.[] | select(contains($m))] | length' | tr -d '\r') || fails=1
gh api -X DELETE "repos/$REPO/issues/$n/labels/in-progress" > /dev/null 2>&1 || true
if [ "${fails:-0}" -ge "$limit" ]; then
  bash "$here/hand-to-human.sh" "$n" "Implementer가 ${fails}번 실패했다($what, 한도 ${limit}번, 마지막 run: $url). 공장은 이 티켓을 더 돌리지 않는다: 사람이 실패 까닭을 보고 고친 뒤 \`ready-for-human\`을 떼고 \`ready-for-agent\`를 붙이며 \`<!-- factory-reset -->\` 댓글을 남긴다."
  exit $?
fi
gh api "repos/$REPO/issues/$n/labels" -f "labels[]=ready-for-agent" > /dev/null \
  || { echo "::warning::record-failure: could not put ready-for-agent back on #$n"; exit 1; }
echo "#$n: $what failure $fails of $limit, back in the queue"
