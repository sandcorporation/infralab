#!/usr/bin/env bash
# Mail bridge of the software factory (ADR-0001 "다리"). Not a workflow: a person's PC or server runs it
# from cron (every 2 minutes). The factory itself never sends mail; this reads its marker comments
# with gh and mails each new one once.
#
#   bridge.sh [--seed]
#
# Looks at the repository's issue and PR comments updated in the last BRIDGE_LOOKBACK_DAYS days (or since
# BRIDGE_SINCE) on open issues and PRs, for:
#
#   <!-- factory-question -->            a question (only while the issue has `needs-decision`)
#   <!-- factory-budget-spec -->         a spec stopped at its budget (`factory-paused`)
#   <!-- factory-budget-daily DATE -->   the whole factory stopped at the daily budget (ledger issue)
#   <!-- factory-human -->               a ticket handed to a person
#   <!-- factory-local -->               a ticket touching workflow or .claude files, left to a local worker
#                                        (local-ticket.sh: `ready-for-human` + `local`)
#   <!-- factory-queue-empty S -->       the last spec S of FACTORY_SPEC_QUEUE was started (ledger issue)
#   <!-- factory-idle Q -->              every spec of the queue is labelled; the factory is idle (ledger)
#   <!-- factory-human-check S -->       spec S's tickets are merged but its check issue has unchecked
#                                        `사람 확인` items, so the spec stays open (human-check.sh gate, #167)
#
# Anyone can write those markers on a public repository, so only comments by `github-actions[bot]` or by
# someone with write access (collaborator permission admin, maintain or write) are sent. A comment by
# anyone else is never sent and its id is remembered so it is not looked at again. Each author's
# permission is asked once per run.
#
# It sends each comment it has not sent before:
#
#   switchboard send --to <recipient> --task <name>-factory --idempotency-key <name>-factory-<comment id>
#     --subject … --body …
#
# The recipient depends on the kind (owner's decision 2026-11-18): a question and a human-check go to
# the boss (BRIDGE_TO_BOSS), because only the owner decides or checks them by hand; every other kind (budget-spec, budget-daily, human,
# local, queue-empty, idle) goes straight to the repository's coordinator (BRIDGE_TO_COORD), who
# acts on it.
#
# A kind that goes to the coordinator is also sent, one mail each, to every recipient in BRIDGE_CC
# (2026-11-19: the factory stopped on a ticket handed to a person and the boss never heard of it, because
# only the coordinator was told). The coordinator's mail keeps the key <name>-factory-<comment id>; a CC
# recipient's key is <name>-factory-<comment id>-cc-<recipient with every character outside
# [A-Za-z0-9._-] made ->. A comment id in the state file means every recipient has it, so markers sent
# before BRIDGE_CC was set are never sent to the new recipients (no flood of old markers when it is first
# set). When one recipient fails, the ones that succeeded are remembered as "<comment id> <recipient>"
# lines and only the others are tried again on the next run.
#
# <name> is the repository name (the part of FACTORY_REPO after the slash).
#
# The body has the kind, the issue link, its title, the comment as written and what to do. The comment
# id is remembered in the state file only after a successful send, so a failed send is tried again on the
# next run (the idempotency key keeps a retry from arriving twice). --seed remembers every marker found
# now without sending anything (run once when installing, so old markers do not all arrive at once).
#
# Environment:
#   FACTORY_REPO          owner/name (default sandcorporation/infralab); gh must be logged in
#   BRIDGE_TO_BOSS        recipient of questions and human-checks (default sandcorp/boss)
#   BRIDGE_TO_COORD       recipient of every other kind (default <name>/coordinator)
#   BRIDGE_CC             more recipients of the coordinator's kinds, separated by spaces (default none);
#                         the coordinator itself is skipped if listed
#   BRIDGE_TO             removed (it sent every kind to one place) and ignored: a warning is printed when
#                         it is still set and the two variables above (or their defaults) are used, so a
#                         leftover BRIDGE_TO can never send a question to the coordinator.
#   SWITCHBOARD_PROFILE   switchboard credential profile (default automation); the profile knows the server
#   BRIDGE_LOOKBACK_DAYS  how far back to read comments (default 14)
#   BRIDGE_SINCE          ISO 8601 time to read from instead (tests)
#   XDG_STATE_HOME        the state file is $XDG_STATE_HOME/<name>-factory-bridge/sent (default under
#                         ~/.local/state), one comment id per line (or "<comment id> <recipient>" while a
#                         CC send is still owed)
#
# Exits 1 when a send failed (the others are still sent). Needs bash, gh, jq and switchboard.
set -u
REPO=${FACTORY_REPO:-sandcorporation/infralab}
NAME=${REPO##*/}
TO_BOSS=${BRIDGE_TO_BOSS:-sandcorp/boss}
TO_COORD=${BRIDGE_TO_COORD:-$NAME/coordinator}
CC=${BRIDGE_CC:-}
if [ -n "${BRIDGE_TO:-}" ]; then
  echo "bridge: BRIDGE_TO is ignored; use BRIDGE_TO_BOSS (questions) and BRIDGE_TO_COORD (the rest)" >&2
fi
export SWITCHBOARD_PROFILE=${SWITCHBOARD_PROFILE:-automation}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$NAME-factory-bridge
SENT=$STATE_DIR/sent

seed=false
case "${1:-}" in
  --seed) seed=true ;;
  "") ;;
  *) echo "usage: bridge.sh [--seed]" >&2; exit 2 ;;
esac

# key <comment id> <recipient> <primary recipient>: the idempotency key of that mail.
key() {
  if [ "$2" = "$3" ]; then echo "$NAME-factory-$1"; return; fi
  echo "$NAME-factory-$1-cc-$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '-')"
}

# Strip any CR jq prints (CRLF output on some platforms).
j() { jq "$@" | tr -d '\r'; }

since() {
  if [ -n "${BRIDGE_SINCE:-}" ]; then echo "$BRIDGE_SINCE"; return; fi
  local t=$(( $(date +%s) - ${BRIDGE_LOOKBACK_DAYS:-14} * 86400 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ
}

mkdir -p "$STATE_DIR" || { echo "bridge: cannot create $STATE_DIR" >&2; exit 1; }
touch "$SENT"

sent() { grep -qxF -- "$1" "$SENT"; }
remember() { echo "$1" >> "$SENT"; }

comments=$(gh api "repos/$REPO/issues/comments?since=$(since)&sort=created&direction=asc&per_page=100" --paginate) \
  || { echo "bridge: could not read the comments of $REPO" >&2; exit 1; }

# One line per marker comment: id <TAB> kind <TAB> issue number <TAB> author login.
matches=$(printf '%s' "$comments" | j -s -r '
  add // [] | .[]
  | (.body // "") as $b
  | (if ($b | contains("<!-- factory-question -->")) then "question"
     elif ($b | contains("<!-- factory-budget-spec -->")) then "budget-spec"
     elif ($b | contains("<!-- factory-budget-daily ")) then "budget-daily"
     elif ($b | contains("<!-- factory-human -->")) then "human"
     elif ($b | contains("<!-- factory-local -->")) then "local"
     elif ($b | contains("<!-- factory-queue-empty ")) then "queue-empty"
     elif ($b | contains("<!-- factory-idle ")) then "idle"
     elif ($b | contains("<!-- factory-human-check ")) then "human-check"
     else empty end) as $k
  | [(.id | tostring), $k, (.issue_url | sub(".*/"; "")), (.user.login // "")] | @tsv')

# trusted <login>: github-actions[bot], the factory App sandcorp-factory[bot] (#172) or a collaborator with write access. Each answer is kept in
# $trust ("<login> yes|no" lines, plain bash 3) so an author is asked once per run.
# Returns 0 trusted, 1 not trusted, 2 the permission could not be read (tried again next run).
trust=
trusted() {
  local login=$1 p v
  case "$login" in "github-actions[bot]" | "sandcorp-factory[bot]") return 0 ;; esac
  [ -n "$login" ] || return 1
  v=$(printf '%s\n' "$trust" | sed -n "s/^$login //p" | head -n 1)
  if [ -z "$v" ]; then
    p=$(gh api "repos/$REPO/collaborators/$login/permission") || return 2
    if [ "$(printf '%s' "$p" | j -r '[.permission, .role_name]
        | any(. == "admin" or . == "maintain" or . == "write")')" = true ]; then
      v=yes
    else
      v=no
    fi
    trust="$trust$login $v
"
  fi
  [ "$v" = yes ]
}

failed=0
while IFS=$'\t' read -r id kind n author; do
  [ -n "$id" ] || continue
  sent "$id" && continue
  trusted "$author"
  case $? in
    0) ;;
    1) remember "$id"; echo "bridge: ignored $kind #$n by ${author:-?} (no write access, comment $id)"
       continue ;;
    *) echo "bridge: could not read the permission of $author; will retry" >&2; failed=1; continue ;;
  esac
  issue=$(gh api "repos/$REPO/issues/$n") || { echo "bridge: could not read #$n" >&2; failed=1; continue; }
  [ "$(printf '%s' "$issue" | j -r '.state')" = open ] || continue
  if [ "$kind" = question ] \
    && [ "$(printf '%s' "$issue" | j -r 'any(.labels[]; .name == "needs-decision")')" != true ]; then
    continue # answered already; not remembered, so a question asked again is still sent
  fi
  if $seed; then remember "$id"; continue; fi

  title=$(printf '%s' "$issue" | j -r '.title')
  url=$(printf '%s' "$issue" | j -r '.html_url')
  comment=$(printf '%s' "$comments" | j -s -r --argjson id "$id" 'add // [] | map(select(.id == $id)) | .[0]')
  body=$(printf '%s' "$comment" | j -r '.body // ""')
  link=$(printf '%s' "$comment" | j -r '.html_url // empty')
  case "$kind" in
    question)
      label="질문"
      todo="이슈에 답 댓글을 달고 needs-decision 라벨을 떼면 공장이 이어 간다." ;;
    budget-spec)
      label="spec 상한 멈춤"
      todo="spec 본문의 \`예산: \$N\` 줄을 올리고 factory-paused 라벨을 떼면 이어 간다." ;;
    budget-daily)
      label="하루 상한 멈춤"
      todo="할 일 없음: KST 0시가 지나면 공장이 스스로 다시 돈다." ;;
    human)
      label="사람 넘김"
      todo="공장이 이 이슈를 사람에게 넘겼다(ready-for-human). 위 댓글의 까닭을 보고 이어 받는다." ;;
    local)
      label="로컬 작업자 몫"
      todo="공장이 이 티켓을 공장 밖에 두었다(ready-for-human + local, workflow·.claude 파일). 로컬 작업자가 구현한다." ;;
    queue-empty)
      label="spec 큐 바닥남"
      todo="다음 spec을 FACTORY_SPEC_QUEUE에 넣는다(조율자 몫)." ;;
    idle)
      label="공장 idle"
      todo="FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다(조율자 몫)." ;;
    human-check)
      label="사람 확인 대기"
      todo="이 확인 이슈의 항목을 손으로 확인해 체크한다(문제는 새 이슈로). 모두 체크하거나 이슈를 닫으면 다음 dispatch 때 spec이 닫히고 공장이 다음 spec으로 간다." ;;
  esac
  text="종류: $label
이슈: $url
제목: #$n $title
댓글: ${link:-$url}

$body

할 일: $todo"
  to=$TO_COORD
  case "$kind" in question|human-check) to=$TO_BOSS ;; esac
  recipients=$to
  if [ "$to" = "$TO_COORD" ]; then
    for r in $CC; do
      case " $recipients " in *" $r "*) ;; *) recipients="$recipients $r" ;; esac
    done
  fi
  done_to=
  ok=true
  for r in $recipients; do
    if grep -qxF -- "$id $r" "$SENT"; then continue; fi
    if switchboard send --to "$r" --task "$NAME-factory" --idempotency-key "$(key "$id" "$r" "$to")" \
      --subject "[$NAME 공장] $label: #$n $title" --body "$text" > /dev/null; then
      done_to="$done_to $r"
      echo "bridge: sent $kind #$n to $r (comment $id)"
    else
      echo "bridge: could not send $kind #$n to $r (comment $id); will retry" >&2
      ok=false
      failed=1
    fi
  done
  if $ok; then
    remember "$id"
  else
    for r in $done_to; do remember "$id $r"; done
  fi
done <<< "$matches"

if $seed; then echo "bridge: seeded $(wc -l < "$SENT" | tr -d ' ') comment ids"; fi
exit "$failed"
