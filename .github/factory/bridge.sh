#!/usr/bin/env bash
# Mail bridge of the software factory (ADR-0001 "다리", #192). Not a workflow: a person's PC or server
# runs it from cron (every 2 minutes). The factory itself never sends mail; this reads the repository
# with gh and mails what waits for a person, once.
#
#   bridge.sh [--seed]
#
# What it sends:
#
# 1. Labels. An open issue (or PR) carrying one of these labels waits for a person (#192: a label
#    without a marker comment used to reach nobody, #166):
#
#      needs-decision   a question only the owner decides                  → BRIDGE_TO_BOSS
#      human-check      a check issue (human-check.sh); only while its body
#                       still has an unchecked `- [ ]` item                 → BRIDGE_TO_BOSS
#      ready-for-human  an issue handed to a person (hand-to-human.sh); with
#                       `local` too it is a local worker's ticket (local-ticket.sh) → BRIDGE_TO_COORD + BRIDGE_CC
#      factory-paused   a spec stopped at its budget                       → BRIDGE_TO_COORD + BRIDGE_CC
#
#    It is mailed once per (issue, label, time the label was put on, recipient). The time is the last
#    `labeled` event of that label in the issue's timeline, so taking the label off and putting it on
#    again is a new mail. The label itself is trusted (only someone with write access can put it on).
#    The reason in the mail is the issue's latest `<!-- factory-… -->` marker comment by a trusted
#    author (below), quoted; without one the mail says 「까닭 댓글 없음」 and is sent anyway.
#    needs-triage, needs-info and `local` alone are not mailed. An issue a person deferred (label
#    `deferred`, #238 from facet#437) waits for nobody: it is not mailed as ready-for-human even when
#    that label was left on.
#
# 2. Marker comments that have no label of their own:
#
#      <!-- factory-budget-daily DATE -->   the whole factory stopped at the daily budget (ledger issue)
#      <!-- factory-queue-empty S -->       the last spec S of FACTORY_SPEC_QUEUE was started (ledger)
#      <!-- factory-idle Q -->              every spec of the queue is labelled; the factory is idle (ledger)
#                                           → BRIDGE_TO_COORD + BRIDGE_CC
#      <!-- factory-human-check S -->       spec S's tickets are merged but its check issue still has
#                                           unchecked items, so the spec is held (human-check.sh gate,
#                                           #167; again when new items arrive)  → BRIDGE_TO_BOSS
#
#    The other markers (factory-question, factory-budget-spec, factory-human, factory-local, …) are only
#    quoted as the reason of a label mail. Anyone can write markers on a public repository, so only
#    comments by `github-actions[bot]`, the factory App `sandcorp-factory[bot]` (#172) or someone with
#    write access (collaborator permission admin, maintain or write) are sent or quoted; a marker comment
#    by anyone else is never sent and its id is remembered. Each author's permission is asked once per run.
#
# 3. Idle, seen directly: when FACTORY_SPEC_QUEUE is set, every spec in it is closed and no open issue has
#    `ready-for-agent` or `in-progress`, the factory is idle → BRIDGE_TO_COORD + BRIDGE_CC, once per queue
#    value. It shares its state with the `factory-idle` marker of the same queue, so the two never both
#    arrive.
#
# Every send is
#
#   switchboard send --to <recipient> --task <name>-factory --idempotency-key <key> \
#     --subject "[<name> 공장] …" --body …
#
# <name> is the name part of FACTORY_REPO (owner/name). Keys: a label mail
# <name>-factory-label-<n>-<label>-<time>-<recipient>, an idle mail <name>-factory-idle-<queue>-<recipient>,
# a marker comment <name>-factory-<comment id> to its first recipient (BRIDGE_TO_COORD, or BRIDGE_TO_BOSS
# for a human-check) and <name>-factory-<comment id>-cc-<recipient> to the others (as before #192), each
# with every character outside [A-Za-z0-9._-] made -.
#
# Recipients are names in the switchboard mailbox and are given only by the environment (the cron line);
# the script has none. Without BRIDGE_TO_COORD nothing is read or sent (exit 2). Without BRIDGE_TO_BOSS the
# boss's mails (needs-decision, human-check) are held, not remembered, and sent on the first run that has
# it; everything else is still sent, and the run exits 1.
#
# State file `sent`, one line per thing sent:
#
#   <comment id>                           a marker comment every recipient has (or one not trusted)
#   <comment id> <recipient>               that comment sent to one recipient while another still failed
#   label <n> <label> <time> <recipient>   a label mail
#   idle <queue> <recipient>               an idle mail
#   labels-seeded                          the label part has run on this file (see below)
#
# A line is written only after a successful send, so a failed send is tried again next run (the
# idempotency key keeps a retry from arriving twice). --seed remembers everything that would be sent now
# (marker comments, labels as they are now, idle) without sending: run it once when installing.
#
# Upgrading from the marker-only bridge (#192): the first run on a state file that has lines but no
# `labels-seeded` line sends no label mail whose reason comment (the latest trusted marker) is already in
# the file: that wait was mailed by the old bridge, so it is only remembered. A labelled issue whose
# reason was never mailed (no marker at all, as on #166) is sent once. Then `labels-seeded` is written.
#
# Environment:
#   FACTORY_REPO          owner/name (default sandcorporation/infralab); gh must be logged in
#   BRIDGE_TO_COORD       recipient of everything but the boss's kinds (required)
#   BRIDGE_TO_BOSS        recipient of needs-decision and human-check (required for those; see above)
#   BRIDGE_CC             more recipients of BRIDGE_TO_COORD's kinds, separated by commas or spaces
#                         (optional; BRIDGE_TO_COORD or a name listed twice gets one mail)
#   BRIDGE_TO             removed and ignored (a warning is printed while it is set)
#   FACTORY_SPEC_QUEUE    the spec queue (spec numbers, space- or comma-separated) for the idle check
#   SWITCHBOARD_PROFILE   switchboard credential profile (default automation); the profile knows the server
#   BRIDGE_LOOKBACK_DAYS  how far back to read marker comments (default 14)
#   BRIDGE_SINCE          ISO 8601 time to read comments from instead (tests)
#   BRIDGE_STATE_DIR      folder of the state file; default $XDG_STATE_HOME/<name>-factory-bridge
#   XDG_STATE_HOME        default ~/.local/state
#
# Exits 1 when a read or a send failed or a boss mail is held (the rest is still sent), 2 on a usage or
# setup error. Needs bash, gh, jq and switchboard.
set -u
REPO=${FACTORY_REPO:-sandcorporation/infralab}
NAME=${REPO##*/}
if [ -n "${BRIDGE_TO:-}" ]; then
  echo "bridge: BRIDGE_TO is ignored; use BRIDGE_TO_BOSS (needs-decision, human-check) and BRIDGE_TO_COORD (the rest)" >&2
fi
TO_BOSS=${BRIDGE_TO_BOSS:-}
TO_COORD=${BRIDGE_TO_COORD:-}
if [ -z "$TO_COORD" ]; then
  echo "bridge: set BRIDGE_TO_COORD (the recipients have no default); nothing sent" >&2
  exit 2
fi
export SWITCHBOARD_PROFILE=${SWITCHBOARD_PROFILE:-automation}
STATE_DIR=${BRIDGE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$NAME-factory-bridge}
SENT=$STATE_DIR/sent

seed=false
case "${1:-}" in
  --seed) seed=true ;;
  "") ;;
  *) echo "usage: bridge.sh [--seed]" >&2; exit 2 ;;
esac

# jq on Windows prints CRLF; strip the CR everywhere.
j() { jq "$@" | tr -d '\r'; }

since() {
  if [ -n "${BRIDGE_SINCE:-}" ]; then echo "$BRIDGE_SINCE"; return; fi
  local t=$(( $(date +%s) - ${BRIDGE_LOOKBACK_DAYS:-14} * 86400 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ
}

mkdir -p "$STATE_DIR" || { echo "bridge: cannot create $STATE_DIR" >&2; exit 2; }
touch "$SENT"

sent() { grep -qxF -- "$1" "$SENT"; }
remember() { echo "$1" >> "$SENT"; }
# A key part: every character outside [A-Za-z0-9._-] made -.
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }
# Recipients one per line, blanks and repeats dropped.
uniq_lines() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | awk '!seen[$0]++'; }

# The old bridge's state file, not upgraded yet: label mails whose reason it sent are only remembered.
upgrading=false
if [ -s "$SENT" ] && ! sent labels-seeded; then upgrading=true; fi

coord_and_cc=$(printf '%s\n%s\n' "$TO_COORD" "$(printf '%s' "${BRIDGE_CC:-}" | tr ', \t' '\n\n\n')" | uniq_lines)

# trusted <login>: github-actions[bot], the factory App or a collaborator with write access. Each answer
# is kept in $trust ("<login> yes|no" lines, plain bash 3) so an author is asked once per run.
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
held=0

# send <recipient> <key> <subject> <text> <what>: one mail; 0 when sent.
send() {
  if switchboard send --to "$1" --task "$NAME-factory" --idempotency-key "$2" \
    --subject "$3" --body "$4" > /dev/null; then
    echo "bridge: sent $5 to $1"
  else
    echo "bridge: could not send $5 to $1; will retry" >&2
    failed=1
    return 1
  fi
}

# deliver <state key base> <key base> <recipients, one per line> <subject> <text> <what>
# Sends to each recipient whose line `<state key base> <recipient>` is not in the state file yet (under
# --seed, or with quiet=true, only remembers it).
quiet=false
deliver() {
  local base=$1 kbase=$2 recipients=$3 subject=$4 text=$5 what=$6 to line
  while IFS= read -r to; do
    [ -n "$to" ] || continue
    line="$base $to"
    sent "$line" && continue
    if $seed || $quiet; then remember "$line"; continue; fi
    send "$to" "$kbase-$(slug "$to")" "$subject" "$text" "$what" && remember "$line"
  done <<< "$recipients"
}

# --- 1. labels -------------------------------------------------------------------------------------

# reason <issue number>: sets $why to the issue's latest trusted marker comment, quoted (or 까닭 댓글
# 없음), and $why_id to that comment's id (empty without one).
reason() {
  local n=$1 cs lines id author body
  why_id=
  cs=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate) \
    || { why="(까닭 댓글을 읽지 못함)"; return 1; }
  # Marker comments newest first: id <TAB> author.
  lines=$(printf '%s' "$cs" | j -s -r 'add // [] | map(select((.body // "") | contains("<!-- factory-")))
    | sort_by(.created_at) | reverse | .[] | [(.id | tostring), (.user.login // "")] | @tsv')
  while IFS=$'\t' read -r id author; do
    [ -n "$id" ] || continue
    trusted "$author" || continue
    body=$(printf '%s' "$cs" | j -s -r --argjson id "$id" 'add // [] | map(select(.id == $id)) | .[0].body // ""')
    why=$(printf '%s\n' "$body" | sed 's/^/> /')
    why_id=$id
    return 0
  done <<< "$lines"
  why="까닭 댓글 없음"
}

labels_ok=true
for label in needs-decision human-check ready-for-human factory-paused; do
  list=$(gh api "repos/$REPO/issues?state=open&labels=$label&per_page=100" --paginate) \
    || { echo "bridge: could not list the issues labelled $label" >&2; failed=1; labels_ok=false; continue; }
  numbers=$(printf '%s' "$list" | j -s -r --arg l "$label" 'add // [] | .[]
    | select(.state == "open" and any(.labels[]; .name == $l))
    | select($l != "human-check" or ((.body // "") | test("(^|\n)[ \t]*[-*+] \\[ \\]")))
    | select($l != "ready-for-human" or (any(.labels[]; .name == "deferred") | not))
    | .number')
  case $label in
    needs-decision) recipients=$TO_BOSS ;;
    human-check) recipients=$TO_BOSS ;;
    *) recipients=$coord_and_cc ;;
  esac
  for n in $numbers; do
    if [ -z "$recipients" ]; then
      echo "bridge: $label #$n is held: set BRIDGE_TO_BOSS" >&2
      held=1 labels_ok=false
      continue
    fi
    tl=$(gh api "repos/$REPO/issues/$n/timeline?per_page=100" --paginate) \
      || { echo "bridge: could not read the timeline of #$n" >&2; failed=1; labels_ok=false; continue; }
    at=$(printf '%s' "$tl" | j -s -r --arg l "$label" 'add // [] | map(select(.event == "labeled"
      and (.label.name // "") == $l)) | sort_by(.created_at) | last | .created_at // "unknown"')
    base="label $n $label $at"
    # Everything sent already (the usual run): skip without reading anything else.
    todo_any=false
    while IFS= read -r to; do
      [ -n "$to" ] && ! sent "$base $to" && todo_any=true
    done <<< "$recipients"
    $todo_any || continue
    if $seed; then deliver "$base" "" "$recipients" "" "" ""; continue; fi
    issue=$(printf '%s' "$list" | j -s -c --argjson n "$n" 'add // [] | map(select(.number == $n)) | .[0]')
    title=$(printf '%s' "$issue" | j -r '.title')
    url=$(printf '%s' "$issue" | j -r '.html_url')
    if ! reason "$n"; then echo "bridge: could not read the comments of #$n" >&2; failed=1; labels_ok=false; continue; fi
    quiet=false
    if $upgrading && [ -n "$why_id" ] && grep -q "^$why_id\( \|$\)" "$SENT"; then
      quiet=true
      echo "bridge: $label #$n was mailed by the old bridge (comment $why_id); remembered"
    fi
    case $label in
      needs-decision)
        kind="질문"
        todo="이슈에 답 댓글을 달고 needs-decision 라벨을 떼면 공장이 이어 간다." ;;
      human-check)
        kind="사람 확인"
        todo="이 확인 이슈의 미체크 항목을 손으로 확인해 체크한다(문제는 새 이슈로). 모두 체크하거나 이슈를 닫으면 다음 dispatch 때 spec이 닫히고 공장이 다음 spec으로 간다." ;;
      ready-for-human)
        if [ "$(printf '%s' "$issue" | j -r 'any(.labels[]; .name == "local")')" = true ]; then
          kind="로컬 작업자 몫"
          todo="공장이 이 티켓을 공장 밖에 두었다(ready-for-human + local, workflow·.claude 파일). 로컬 작업자가 구현한다."
        else
          kind="사람 넘김"
          todo="공장이 이 이슈를 사람에게 넘겼다. 까닭을 보고 이어 받는다(다시 공장에 넣으려면 ready-for-human을 떼고 ready-for-agent를 붙이며 \`<!-- factory-reset -->\` 댓글을 남긴다)."
        fi ;;
      factory-paused)
        kind="spec 상한 멈춤"
        todo="spec 본문의 \`예산: \$N\` 줄을 올리고 factory-paused 라벨을 떼면 이어 간다." ;;
    esac
    text="종류: $kind ($label)
이슈: $url
제목: #$n $title
라벨 붙은 시각: $at

까닭:
$why

할 일: $todo"
    deliver "$base" "$NAME-factory-label-$n-$label-$(slug "$at")" "$recipients" \
      "[$NAME 공장] $kind: #$n $title" "$text" "$label #$n"
    quiet=false
  done
done
if $labels_ok && ! sent labels-seeded; then remember labels-seeded; fi

# --- 2. marker comments ----------------------------------------------------------------------------

comments=$(gh api "repos/$REPO/issues/comments?since=$(since)&sort=created&direction=asc&per_page=100" --paginate) \
  || { echo "bridge: could not read the comments of $REPO" >&2; exit 1; }

# One line per marker comment: id <TAB> kind <TAB> issue number <TAB> author login <TAB> marker value.
matches=$(printf '%s' "$comments" | j -s -r '
  add // [] | .[]
  | (.body // "") as $b
  | (if ($b | contains("<!-- factory-budget-daily ")) then "budget-daily"
     elif ($b | contains("<!-- factory-queue-empty ")) then "queue-empty"
     elif ($b | contains("<!-- factory-idle ")) then "idle"
     elif ($b | contains("<!-- factory-human-check ")) then "human-check"
     else empty end) as $k
  | ($b | capture("<!-- factory-" + $k + " (?<v>[^ ]*) -->").v // "") as $v
  | [(.id | tostring), $k, (.issue_url | sub(".*/"; "")), (.user.login // ""), $v] | @tsv')

while IFS=$'\t' read -r id kind n author value; do
  [ -n "$id" ] || continue
  sent "$id" && continue
  if [ "$kind" = human-check ]; then recipients=$TO_BOSS; else recipients=$coord_and_cc; fi
  # An idle marker shares its state with the direct idle check (part 3).
  if [ "$kind" = idle ]; then base="idle $value"; else base=$id; fi
  pending=
  while IFS= read -r to; do
    [ -n "$to" ] || continue
    sent "$base $to" || pending="$pending$to
"
  done <<< "$recipients"
  if [ -z "$recipients" ]; then
    echo "bridge: $kind #$n is held: set BRIDGE_TO_BOSS" >&2
    held=1
    continue
  fi
  if [ -z "$pending" ]; then remember "$id"; continue; fi
  trusted "$author"
  case $? in
    0) ;;
    1) remember "$id"
       echo "bridge: ignored $kind #$n by ${author:-?} (no write access, comment $id)"
       continue ;;
    *) echo "bridge: could not read the permission of $author; will retry" >&2; failed=1; continue ;;
  esac
  issue=$(gh api "repos/$REPO/issues/$n") || { echo "bridge: could not read #$n" >&2; failed=1; continue; }
  [ "$(printf '%s' "$issue" | j -r '.state')" = open ] || continue
  if $seed; then
    if [ "$kind" = idle ]; then
      while IFS= read -r to; do [ -n "$to" ] && remember "$base $to"; done <<< "$pending"
    fi
    remember "$id"; continue
  fi

  title=$(printf '%s' "$issue" | j -r '.title')
  url=$(printf '%s' "$issue" | j -r '.html_url')
  comment=$(printf '%s' "$comments" | j -s -r --argjson id "$id" 'add // [] | map(select(.id == $id)) | .[0]')
  body=$(printf '%s' "$comment" | j -r '.body // ""')
  link=$(printf '%s' "$comment" | j -r '.html_url // empty')
  case "$kind" in
    budget-daily)
      label="하루 상한 멈춤"
      todo="할 일 없음: KST 0시가 지나면 공장이 스스로 다시 돈다." ;;
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
  subject="[$NAME 공장] $label: #$n $title"
  first=$(printf '%s\n' "$recipients" | head -n 1)
  ok=true
  while IFS= read -r to; do
    [ -n "$to" ] || continue
    if [ "$kind" = idle ]; then key="$NAME-factory-idle-$(slug "$value")-$(slug "$to")"
    elif [ "$to" = "$first" ]; then key="$NAME-factory-$id"
    else key="$NAME-factory-$id-cc-$(slug "$to")"; fi
    if send "$to" "$key" "$subject" "$text" "$kind #$n (comment $id)"; then
      remember "$base $to"
    else
      ok=false
    fi
  done <<< "$pending"
  $ok && remember "$id"
done <<< "$matches"

# --- 3. idle, seen directly ------------------------------------------------------------------------

queue=$(printf '%s' "${FACTORY_SPEC_QUEUE:-}" | tr -s ' \t\r\n,' '-' | sed 's/^-//; s/-$//')
if [ -n "$queue" ]; then
  idle=true
  for s in $(printf '%s' "$queue" | tr '-' ' '); do
    st=$(gh api "repos/$REPO/issues/$s" --jq '.state' | tr -d '\r') || { idle=false; failed=1; break; }
    [ "$st" = closed ] || { idle=false; break; }
  done
  if $idle; then
    for l in ready-for-agent in-progress; do
      c=$(gh api "repos/$REPO/issues?state=open&labels=$l&per_page=100" --paginate \
        | j -s --arg l "$l" 'add // [] | map(select(.state == "open" and any(.labels[]; .name == $l))) | length') \
        || { idle=false; failed=1; break; }
      [ "$c" = 0 ] || { idle=false; break; }
    done
  fi
  if $idle; then
    text="종류: 공장 idle
큐: FACTORY_SPEC_QUEUE=${FACTORY_SPEC_QUEUE}

큐의 spec이 모두 닫혔고 ready-for-agent·in-progress 열린 이슈가 없다.

할 일: FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다(조율자 몫)."
    deliver "idle $queue" "$NAME-factory-idle-$(slug "$queue")" "$coord_and_cc" \
      "[$NAME 공장] 공장 idle: 큐 $queue 끝" "$text" "idle ($queue)"
  fi
fi

if $seed; then echo "bridge: seeded $(wc -l < "$SENT" | tr -d ' ') lines"; fi
[ "$held" = 0 ] || failed=1
exit "$failed"
