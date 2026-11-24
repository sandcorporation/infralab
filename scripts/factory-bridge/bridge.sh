#!/usr/bin/env bash
# .github/factory/bridge.sh(kit 사본)의 Orca 판. kit 이 Orca 판을 받으면 이 파일을 지우고 kit 판으로 돌아간다.
#
# Mail bridge of the software factory (spec #249 "다리", #410). Not a workflow: a person's PC or server
# runs it from cron (every 2 minutes). The factory itself never sends mail; this reads the repository
# with gh and mails what waits for a person, once, as Orca mail (`orca orchestration send`).
#
#   bridge.sh [--seed]
#
# What it sends (#410 "더함 2"):
#
# 1. Labels. An open issue (or PR) carrying one of these labels waits for a person:
#
#      needs-decision   a question only the owner decides           → boss
#      ready-for-human  a ticket handed to a person (hand-to-human.sh)→ coord + BRIDGE_CC
#      factory-paused   a spec stopped at its budget                 → coord + BRIDGE_CC
#      human-check      a person must check something; only while the body still has an
#                       unchecked `- [ ]` item (`*`/`+` bullets and indents too)
#                                                                    → coord + BRIDGE_CC, or
#                                                                      boss (BRIDGE_HUMAN_CHECK_TO=boss)
#
#    It is mailed once per (issue, label, time the label was put on, recipient). The time is the last
#    `labeled` event of that label in the issue's timeline, so taking the label off and putting it on
#    again is a new mail. The label itself is trusted (only someone with write access can put it on).
#    The reason in the mail is the issue's latest `<!-- factory-… -->` marker comment by a trusted
#    author (below); without one the mail says 「까닭 댓글 없음」 and is sent anyway.
#    needs-triage, needs-info and local are not mailed; ready-for-human together with local is mailed as
#    「로컬 작업자 몫」 (the factory left the ticket outside itself; a local worker implements it). An issue
#    a person deferred (label `deferred`,
#    #437) waits for nobody: it is not mailed as ready-for-human even when that label was left on.
#
#    ready-for-human and factory-paused are mailed only when the last `labeled` event is by
#    github-actions[bot] or a BRIDGE_TRUSTED_BOTS login (#502). Put on by a person (a coordinator
#    pausing a spec or taking a ticket by hand) they get one status line and no mail. A daily budget
#    marker whose cap is $0 is mailed as a stop on purpose, not as "midnight starts it again".
#
#    For ready-for-human, factory-paused and human-check the coord mail is a processing
#    order (#437): its 할 일 is four steps (원인 확인 → 고침 → 재발 방지 장치 → 결과 보고) and says not
#    to wait for another order; BRIDGE_CC gets one line only (kind, issue, title) with the same key
#    per recipient. For ready-for-human the kind carries the hand-over code from the latest trusted
#    `<!-- factory-human <code> -->` comment (`사람 넘김(conflict)`), in the subject and the first line;
#    the old marker without a code counts as `other`. needs-decision mail is as before.
#
# 2. Marker comments without a label, left on the ledger issue (or the `bench-alert` issue):
#
#      <!-- factory-budget-daily DATE -->      the whole factory stopped at the daily budget
#      <!-- factory-queue-empty S -->          the last spec S of FACTORY_SPEC_QUEUE was started
#      <!-- factory-idle Q -->                 every spec of the queue is labelled; the factory is idle
#      <!-- factory-stalled DATE -->           waiting tickets are blocked by issues handed to a person
#      <!-- factory-stalled deferred-B-T -->   a deferred issue B blocks the waiting ticket T (once, #437)
#      <!-- factory-bench-regression SHA -->   the hourly benchmark failed at SHA (#366)
#      <!-- factory-human-check SPEC -->       a person must check the issue (routed like human-check)
#
#    Each comment goes to coord and BRIDGE_CC once. Anyone can write those markers on a
#    public repository, so only comments by `github-actions[bot]`, a BRIDGE_TRUSTED_BOTS login or someone
#    with write access
#    (collaborator permission admin, maintain or write) are sent; a comment by anyone else is never sent
#    and its id is remembered. Each author's permission is asked once per run.
#
# 3. Idle, seen directly: when FACTORY_SPEC_QUEUE is set, every spec in it is closed and no open issue
#    has `ready-for-agent` or `in-progress`, the factory is idle → coord + BRIDGE_CC, once per
#    queue value. It shares its key with the `factory-idle` marker of the same queue, so the two never
#    both arrive.
#
# Recipients. The bridge knows two logical recipients, `coord` (the coordinator session) and `boss`
# (the owner's bot). Their Orca addresses are not in this script: the notify config (below) names them,
# and send() alone turns a logical name into an Orca address. A process outside a terminal (cron) can
# only send with `--from <a live terminal handle>`, so every run looks the coordinator terminal up
# (`orca terminal list --worktree path:<BRIDGE_COORD_WORKTREE> --json`, the terminal titled
# BRIDGE_COORD_TITLE) and every send is
#
#   coord: orca orchestration send --type status --from <handle> --to <handle> \
#            --subject "[<name> 공장] …" --body-file -
#   boss:  orca orchestration send --type status --from <handle> --on <BRIDGE_BOSS_ON> --to <BRIDGE_BOSS_TO> …
#
# Without the coordinator terminal nothing is sent (and nothing remembered) that run. Logs and errors
# name the logical recipient only, never an address or a handle.
#
# <name> is the name part of FACTORY_REPO (owner/name), so one copy serves any repository's factory: run
# one cron line per repository with its own FACTORY_REPO and notify config (#380).
#
# Notify config: an env-style file (KEY=value lines; `export `, quotes, blank and `#` lines allowed; it
# is read, never sourced) at BRIDGE_NOTIFY_ENV. bridge-notify.env.example next to this script lists:
#   BRIDGE_COORD_WORKTREE  the coordinator's folder (the `path:` worktree selector)
#   BRIDGE_COORD_TITLE     the title of the coordinator's terminal in that folder
#   BRIDGE_BOSS_ON         the Orca server of the owner's bot (`--on`)
#   BRIDGE_BOSS_TO         the owner's bot (`--to`, e.g. bot:<name>)
#   BRIDGE_LEGACY_COORD    optional: old recipient names of the coordinator in the state file
#   BRIDGE_LEGACY_BOSS     optional: the same for the owner (both space- or comma-separated)
# A missing file or an empty required key stops the bridge with exit 2 naming what is missing.
#
# State file `sent` (one line per thing sent, per recipient):
#
#   <comment id>                           a marker comment sent to coord (as before #410;
#                                          before #410 also a comment not trusted)
#   <comment id> ignored                   a marker comment not trusted (never sent)
#   <comment id> <recipient>               the copy of that comment to a BRIDGE_CC recipient (also read for coord)
#   label <n> <label> <time> <recipient>   a label mail
#   idle <queue> <recipient>               an idle mail
#
# <recipient> is a logical name (coord, boss). A line is written only after a successful send, so a failed
# send is tried again next run (Orca mail has no idempotency key: the state file alone keeps a mail from
# going twice). A state file written when recipients were mailbox addresses is moved over at the start of
# every run: a last field listed in BRIDGE_LEGACY_COORD / BRIDGE_LEGACY_BOSS becomes coord / boss, so the
# first run after the move sends nothing already sent. --seed remembers everything that would be sent now
# (comments, labels as they are now, idle) without sending: run it once when installing or upgrading, so
# what already waits does not all arrive at once.
#
# Environment:
#   FACTORY_REPO          owner/name; without it, the `origin` remote of the git checkout holding this
#                         script (then of the working directory) when that is a GitHub URL, else exit 2
#                         (#437: no repository is named here, so a copy serves any repository).
#                         gh must be logged in
#   BRIDGE_NOTIFY_ENV     the notify config (above); default
#                         ${XDG_CONFIG_HOME:-~/.config}/<name>-factory-bridge/bridge-notify.env
#   BRIDGE_CC             more logical recipients (coord, boss) of everything but needs-decision
#                         (optional; splits on commas, spaces and tabs; empty entries, repeats and coord
#                         itself are dropped; anything else is exit 2)
#   BRIDGE_TRUSTED_BOTS   bot logins (e.g. example-bot[bot]) whose marker comments are trusted like
#                         github-actions[bot] without a permission lookup, and whose ready-for-human /
#                         factory-paused labels are mailed; same separators (optional)
#   BRIDGE_HUMAN_CHECK_TO coord (default): human-check goes to coord + BRIDGE_CC as a
#                         processing order; boss: to boss alone, as a plain mail. Covers the
#                         label and the `<!-- factory-human-check SPEC -->` marker comment
#   BRIDGE_TO, BRIDGE_TO_BOSS, BRIDGE_TO_COORD
#                         removed and ignored (a warning is printed while one is set)
#   FACTORY_SPEC_QUEUE    the spec queue (spec numbers, space- or comma-separated) for the idle check
#   BRIDGE_LOOKBACK_DAYS  how far back to read marker comments (default 14)
#   BRIDGE_SINCE          ISO 8601 time to read comments from instead (tests)
#   BRIDGE_STATE_DIR      folder of the state file; default $XDG_STATE_HOME/<name>-factory-bridge
#   XDG_STATE_HOME        default ~/.local/state
#
# Exits 1 when a read or a send failed (the rest is still sent), 2 on a usage or setup error.
# Needs bash, gh, jq and orca.
set -u
# origin_repo <dir>: owner/name of the GitHub `origin` remote of the git checkout at <dir>, or nothing.
origin_repo() {
  local u
  u=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  u=${u%.git}
  case "$u" in *github.com[:/]*/*) ;; *) return 0 ;; esac
  u=${u#*github.com}; u=${u#[:/]}
  case "$u" in */*/* | /* | */) return 0 ;; esac
  printf '%s' "$u"
}
REPO=${FACTORY_REPO:-}
[ -n "$REPO" ] || REPO=$(origin_repo "$(cd "$(dirname "$0")" && pwd)")
[ -n "$REPO" ] || REPO=$(origin_repo .)
if [ -z "$REPO" ]; then
  echo "bridge: set FACTORY_REPO=owner/name (no GitHub origin remote found to fall back to)" >&2
  exit 2
fi
NAME=${REPO##*/}
for v in BRIDGE_TO BRIDGE_TO_BOSS BRIDGE_TO_COORD; do
  if [ -n "${!v:-}" ]; then
    echo "bridge: $v is ignored; the recipients are coord and boss, addressed by the notify config (BRIDGE_NOTIFY_ENV)" >&2
  fi
done
# The logical recipients. send() alone turns them into Orca addresses.
TO_BOSS=boss
TO_COORD=coord
# words: split on commas, spaces and tabs, one per line, empty entries dropped.
words() { printf '%s' "$1" | tr ', \t\r' '\n\n\n\n' | sed '/^$/d'; }
# BRIDGE_CC: logical names only; repeats and coord itself dropped; one per line.
CC=$(words "${BRIDGE_CC:-}" | grep -vxF -- "$TO_COORD" | awk '!seen[$0]++')
if printf '%s\n' "$CC" | sed '/^$/d' | grep -qvxF -- "$TO_BOSS"; then
  echo "bridge: BRIDGE_CC takes the logical recipients coord and boss only; nothing sent" >&2
  exit 2
fi
# The notify config: read KEY=value lines, never sourced.
NOTIFY_ENV=${BRIDGE_NOTIFY_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/$NAME-factory-bridge/bridge-notify.env}
if [ ! -f "$NOTIFY_ENV" ] || [ ! -r "$NOTIFY_ENV" ]; then
  echo "bridge: the notify config is missing or unreadable (set BRIDGE_NOTIFY_ENV; see bridge-notify.env.example); nothing sent" >&2
  exit 2
fi
# conf <key>: the last value of <key> in the notify config (quotes around it dropped), or nothing.
conf() {
  awk -v k="$1" '{ sub(/\r$/, ""); sub(/^[ \t]*(export[ \t]+)?/, "") }
    index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
    END { if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2); printf "%s", v }' "$NOTIFY_ENV"
}
COORD_WORKTREE=$(conf BRIDGE_COORD_WORKTREE)
COORD_TITLE=$(conf BRIDGE_COORD_TITLE)
BOSS_ON=$(conf BRIDGE_BOSS_ON)
BOSS_TO=$(conf BRIDGE_BOSS_TO)
missing=
[ -n "$COORD_WORKTREE" ] || missing="$missing BRIDGE_COORD_WORKTREE"
[ -n "$COORD_TITLE" ] || missing="$missing BRIDGE_COORD_TITLE"
[ -n "$BOSS_ON" ] || missing="$missing BRIDGE_BOSS_ON"
[ -n "$BOSS_TO" ] || missing="$missing BRIDGE_BOSS_TO"
if [ -n "$missing" ]; then
  echo "bridge: the notify config has no value for$missing; nothing sent" >&2
  exit 2
fi
# BRIDGE_TRUSTED_BOTS: bot logins trusted like github-actions[bot] (same separators), one per line.
BOTS=$(printf '%s' "${BRIDGE_TRUSTED_BOTS:-}" | tr ', \t\r' '\n\n\n\n' | sed '/^$/d')
# BRIDGE_HUMAN_CHECK_TO: who gets human-check (the label and the factory-human-check marker).
case "${BRIDGE_HUMAN_CHECK_TO:-coord}" in
  boss | coord) HUMAN_CHECK_TO=${BRIDGE_HUMAN_CHECK_TO:-coord} ;;
  *) echo "bridge: BRIDGE_HUMAN_CHECK_TO must be boss or coord, not ${BRIDGE_HUMAN_CHECK_TO}" >&2; exit 2 ;;
esac
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

# Move a state file from mailbox addresses to the logical names (once; a moved file has nothing left to
# move): a last field listed in BRIDGE_LEGACY_COORD / BRIDGE_LEGACY_BOSS becomes coord / boss.
legacy_coord=$(words "$(conf BRIDGE_LEGACY_COORD)" | tr '\n' ' ')
legacy_boss=$(words "$(conf BRIDGE_LEGACY_BOSS)" | tr '\n' ' ')
if [ -n "$legacy_coord$legacy_boss" ]; then
  awk -v c="$legacy_coord" -v b="$legacy_boss" '
    BEGIN { n = split(c, a, " "); for (i = 1; i <= n; i++) m[a[i]] = "coord"
            n = split(b, a, " "); for (i = 1; i <= n; i++) m[a[i]] = "boss" }
    { sub(/\r$/, "") }
    NF >= 2 && ($NF in m) { $NF = m[$NF]; moved++ }
    { print }
    END { print moved + 0 > "/dev/stderr" }' "$SENT" > "$SENT.new" 2> "$SENT.moved" \
    || { echo "bridge: could not move the state file to the logical recipients" >&2; rm -f "$SENT.new" "$SENT.moved"; exit 2; }
  moved=$(tr -d '\r' < "$SENT.moved"); rm -f "$SENT.moved"
  if [ "${moved:-0}" -gt 0 ]; then
    mv "$SENT.new" "$SENT" || { echo "bridge: could not write the state file" >&2; exit 2; }
    echo "bridge: moved $moved state lines to the logical recipients"
  else
    rm -f "$SENT.new"
  fi
fi

sent() { grep -qxF -- "$1" "$SENT"; }
remember() { echo "$1" >> "$SENT"; }

# --- sending -----------------------------------------------------------------------------------------

# coord_handle: the handle of the coordinator terminal, looked up once per run (nothing when not found).
coord_handle= coord_looked=false
find_coord() {
  if ! $coord_looked; then
    coord_looked=true
    local out
    if out=$(orca terminal list --worktree "path:$COORD_WORKTREE" --json 2> /dev/null); then
      coord_handle=$(printf '%s' "$out" | j -r --arg t "$COORD_TITLE" \
        '[.result.terminals[]? | select(.title == $t) | .handle // empty] | first // empty' 2> /dev/null)
    fi
    [ -n "$coord_handle" ] \
      || echo "bridge: the coordinator terminal is not open (BRIDGE_COORD_WORKTREE, BRIDGE_COORD_TITLE); nothing is sent this run" >&2
  fi
  [ -n "$coord_handle" ]
}
# send <coord|boss> <subject> <text>: one Orca mail. The only place that knows the Orca addresses; its
# output and errors name no address or handle.
send() {
  find_coord || return 1
  local rc=0
  case $1 in
    coord) printf '%s\n' "$3" | orca orchestration send --type status --from "$coord_handle" --to "$coord_handle" \
             --subject "$2" --body-file - > /dev/null 2>&1 || rc=$? ;;
    boss)  printf '%s\n' "$3" | orca orchestration send --type status --from "$coord_handle" --on "$BOSS_ON" \
             --to "$BOSS_TO" --subject "$2" --body-file - > /dev/null 2>&1 || rc=$? ;;
    *) return 1 ;;
  esac
  [ "$rc" -eq 0 ] || echo "bridge: orca send to $1 failed (exit $rc)" >&2
  return "$rc"
}

# trusted <login>: github-actions[bot] or a collaborator with write access. Each answer is kept in
# $trust ("<login> yes|no" lines, plain bash 3) so an author is asked once per run.
# Returns 0 trusted, 1 not trusted, 2 the permission could not be read (tried again next run).
trust=
# trusted_bot <login>: github-actions[bot] or a BRIDGE_TRUSTED_BOTS login (no permission lookup).
trusted_bot() {
  [ "$1" = "github-actions[bot]" ] && return 0
  [ -n "$1" ] && [ -n "$BOTS" ] && printf '%s\n' "$BOTS" | grep -qxF -- "$1"
}
trusted() {
  local login=$1 p v
  trusted_bot "$login" && return 0
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

# deliver <state key base> <recipients, one per line> <subject> <text> <what>
# Sends to each recipient whose line `<state key base> <recipient>` is not in the state file yet (or,
# under --seed, only remembers it). The first recipient of a marker comment uses the bare comment id
# as before #410; deliver_comment handles that.
deliver() {
  local base=$1 recipients=$2 subject=$3 text=$4 what=$5 to line
  while IFS= read -r to; do
    [ -n "$to" ] || continue
    line="$base $to"
    sent "$line" && continue
    if $seed; then remember "$line"; continue; fi
    if send "$to" "$subject" "$text"; then
      remember "$line"
      echo "bridge: sent $what to $to"
    else
      echo "bridge: could not send $what to $to; will retry" >&2
      failed=1
    fi
  done <<< "$recipients"
}

coord_and_cc=$(printf '%s\n%s\n' "$TO_COORD" "$CC" | sed '/^$/d' | awk '!seen[$0]++')
# human-check (the label and the factory-human-check marker) goes to the owner alone when
# BRIDGE_HUMAN_CHECK_TO=boss, else to the coordinator and BRIDGE_CC like the rest.
if [ "$HUMAN_CHECK_TO" = boss ]; then human_check_to=$TO_BOSS; else human_check_to=$coord_and_cc; fi
human_check_todo="이 확인 이슈의 미체크 항목을 손으로 확인해 체크한다(문제는 새 이슈로). 모두 체크하거나 이슈를 닫으면 다음 dispatch 때 spec이 닫히고 공장이 다음 spec으로 간다."

# --- 1. labels -------------------------------------------------------------------------------------

# reason <issue number>: the issue's latest marker comment by a trusted author, quoted, or 까닭 댓글 없음.
reason() {
  local n=$1 cs lines id author body
  cs=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate) || { echo "(까닭 댓글을 읽지 못함)"; return; }
  # Marker comments newest first: id <TAB> author.
  lines=$(printf '%s' "$cs" | j -s -r 'add // [] | map(select((.body // "") | contains("<!-- factory-")))
    | sort_by(.created_at) | reverse | .[] | [(.id | tostring), (.user.login // "")] | @tsv')
  while IFS=$'\t' read -r id author; do
    [ -n "$id" ] || continue
    trusted "$author" || continue
    body=$(printf '%s' "$cs" | j -s -r --argjson id "$id" 'add // [] | map(select(.id == $id)) | .[0].body // ""')
    printf '%s\n' "$body" | sed 's/^/> /'
    return
  done <<< "$lines"
  echo "까닭 댓글 없음"
}

# handover_code <issue number>: the code of the issue's latest `<!-- factory-human <code> -->` comment by
# a trusted author (#437); `other` for the old marker without a code, or when there is none.
handover_code() {
  local n=$1 cs lines id author code
  cs=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate) || { echo other; return; }
  # Hand-over markers newest first: id <TAB> author <TAB> code (empty for the old marker).
  lines=$(printf '%s' "$cs" | j -s -r 'add // [] | map(select((.body // "") | contains("<!-- factory-human")))
    | sort_by(.created_at) | reverse | .[]
    | [(.id | tostring), (.user.login // ""),
       ((.body | capture("<!-- factory-human (?<c>[a-z-]+) -->").c) // "")] | @tsv')
  while IFS=$'\t' read -r id author code; do
    [ -n "$id" ] || continue
    trusted "$author" || continue
    echo "${code:-other}"
    return
  done <<< "$lines"
  echo other
}

for label in needs-decision ready-for-human factory-paused human-check; do
  list=$(gh api "repos/$REPO/issues?state=open&labels=$label&per_page=100" --paginate) \
    || { echo "bridge: could not list the issues labelled $label" >&2; failed=1; continue; }
  numbers=$(printf '%s' "$list" | j -s -r --arg l "$label" 'add // [] | .[]
    | select(.state == "open" and any(.labels[]; .name == $l))
    | select($l != "human-check" or ((.body // "") | test("(^|\n)[ \t]*[-*+] \\[ \\]")))
    | select($l != "ready-for-human" or (any(.labels[]; .name == "deferred") | not))
    | .number')
  case $label in
    needs-decision)
      kind="질문"; recipients=$TO_BOSS
      todo="이슈에 답 댓글을 달고 needs-decision 라벨을 떼면 공장이 이어 간다." ;;
    ready-for-human)
      kind="사람 넘김"; recipients=$coord_and_cc
      todo="공장이 이 이슈를 사람에게 넘겼다. 까닭을 보고 이어 받는다(다시 공장에 넣으려면 ready-for-human을 떼고 ready-for-agent를 붙인다)." ;;
    factory-paused)
      kind="spec 상한 멈춤"; recipients=$coord_and_cc
      todo="spec 본문의 \`예산: \$N\` 줄을 올리고 factory-paused 라벨을 떼면 이어 간다." ;;
    human-check)
      kind="사람 확인"; recipients=$human_check_to
      todo=$human_check_todo ;;
  esac
  for n in $numbers; do
    tl=$(gh api "repos/$REPO/issues/$n/timeline?per_page=100" --paginate) \
      || { echo "bridge: could not read the timeline of #$n" >&2; failed=1; continue; }
    at=$(printf '%s' "$tl" | j -s -r --arg l "$label" 'add // [] | map(select(.event == "labeled"
      and (.label.name // "") == $l)) | sort_by(.created_at) | last | .created_at // "unknown"')
    base="label $n $label $at"
    # ready-for-human and factory-paused are the factory's own hand-over and spec stop (#502): mailed only
    # when the last `labeled` event was by github-actions[bot] or a BRIDGE_TRUSTED_BOTS login. A person
    # (a coordinator pausing a spec or taking a ticket by hand) put it on on purpose: one status line, no
    # mail. Without a labeled event (who put it on is unknown) it is mailed as before.
    case $label in ready-for-human | factory-paused)
      by=$(printf '%s' "$tl" | j -s -r --arg l "$label" 'add // [] | map(select(.event == "labeled"
        and (.label.name // "") == $l)) | sort_by(.created_at) | last | .actor.login // ""')
      if [ "$at" != unknown ] && ! trusted_bot "$by"; then
        if ! sent "$base human"; then
          remember "$base human"
          echo "bridge: not mailing $label #$n: put on by ${by:-?} at $at, not by the factory"
        fi
        continue
      fi ;;
    esac
    # Everything sent already (the usual run): skip without reading anything else.
    todo_any=false
    while IFS= read -r to; do
      [ -n "$to" ] && ! sent "$base $to" && todo_any=true
    done <<< "$recipients"
    $todo_any || continue
    if $seed; then deliver "$base" "$recipients" "" "" ""; continue; fi
    issue=$(printf '%s' "$list" | j -s -c --argjson n "$n" 'add // [] | map(select(.number == $n)) | .[0]')
    title=$(printf '%s' "$issue" | j -r '.title')
    url=$(printf '%s' "$issue" | j -r '.html_url')
    why=$(reason "$n")
    if [ "$label" = needs-decision ] || { [ "$label" = human-check ] && [ "$HUMAN_CHECK_TO" = boss ]; }; then
      text="종류: $kind ($label)
이슈: $url
제목: #$n $title
라벨 붙은 시각: $at

까닭:
$why

할 일: $todo"
      deliver "$base" "$recipients" "[$NAME 공장] $kind: #$n $title" "$text" "$label #$n"
      continue
    fi
    # The rest is a processing order for the coordinator (#437): it acts on this mail alone. BRIDGE_CC
    # gets one line only. A hand-over names its code (the latest trusted marker's; the old marker
    # without a code is `other`) in the subject and the first line.
    what=$kind fix=$todo
    [ "$label" = ready-for-human ] && what="$kind($(handover_code "$n"))"
    # ready-for-human + local: the factory left the ticket outside itself on purpose (workflow and .claude
    # files); a local worker implements it.
    if [ "$label" = ready-for-human ] && [ "$(printf '%s' "$list" | j -s --argjson n "$n" 'add // []
        | map(select(.number == $n)) | .[0] | any(.labels[]?; .name == "local")')" = true ]; then
      what="로컬 작업자 몫"
      fix="공장이 이 티켓을 공장 밖에 두었다(ready-for-human + local, workflow·.claude 파일). 로컬 작업자가 구현한다."
    fi
    text="종류: $what ($label)
이슈: $url
제목: #$n $title
라벨 붙은 시각: $at

까닭:
$why

할 일 — 이 메일이 처리 지시다. 다른 지시를 기다리지 않고 차례대로 끝낸다:
1. 원인 확인: 위 까닭과 이슈·PR·run 로그를 읽고 왜 공장이 스스로 끝내지 못했는지 밝힌다.
2. 고침: $fix
3. 재발 방지 장치: 같은 까닭으로 다시 사람에게 넘어오지 않게 공장 장치(스크립트·시험·workflow)를 고치는 티켓을 내거나 고친다.
4. 결과 보고: 원인·고친 것·재발 방지 장치를 이슈 댓글로 남기고 보고한다."
    subject="[$NAME 공장] $what: #$n $title"
    deliver "$base" "$TO_COORD" "$subject" "$text" "$label #$n"
    cc=$(printf '%s\n' "$CC" | grep -vxF -- "$TO_COORD")
    deliver "$base" "$cc" "$subject" "$what #$n $title" "$label #$n (one line)"
  done
done

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
     elif ($b | contains("<!-- factory-stalled ")) then "stalled"
     elif ($b | contains("<!-- factory-bench-regression ")) then "bench-regression"
     elif ($b | contains("<!-- factory-human-check ")) then "human-check"
     else empty end) as $k
  | ($b | capture("<!-- factory-" + $k + " (?<v>[^ ]*) -->").v // "") as $v
  | [(.id | tostring), $k, (.issue_url | sub(".*/"; "")), (.user.login // ""), $v] | @tsv')

# The state key of comment <id> for recipient <to>: the bare id for the coordinator (as before #410).
ckey() { if [ "$2" = "$TO_COORD" ]; then echo "$1"; else echo "$1 $2"; fi; }

while IFS=$'\t' read -r id kind n author value; do
  [ -n "$id" ] || continue
  sent "$id ignored" && continue
  rcpts=$coord_and_cc
  [ "$kind" = human-check ] && rcpts=$human_check_to
  # An idle marker shares its key with the direct idle check (part 3).
  if [ "$kind" = idle ]; then
    pending=
    while IFS= read -r to; do
      [ -n "$to" ] || continue
      sent "idle $value $to" && continue
      [ "$to" = "$TO_COORD" ] && sent "$id" && continue # sent by a bridge before #410
      pending="$pending$to
"
    done <<< "$rcpts"
  else
    pending=
    while IFS= read -r to; do
      [ -n "$to" ] || continue
      # The coordinator copy is the bare id; "<id> <coordinator>" (a copied bridge's form) counts too.
      { sent "$(ckey "$id" "$to")" || sent "$id $to"; } || pending="$pending$to
"
    done <<< "$rcpts"
  fi
  [ -n "$pending" ] || continue
  trusted "$author"
  case $? in
    0) ;;
    1) remember "$id ignored"
       echo "bridge: ignored $kind #$n by ${author:-?} (no write access, comment $id)"
       continue ;;
    *) echo "bridge: could not read the permission of $author; will retry" >&2; failed=1; continue ;;
  esac
  issue=$(gh api "repos/$REPO/issues/$n") || { echo "bridge: could not read #$n" >&2; failed=1; continue; }
  [ "$(printf '%s' "$issue" | j -r '.state')" = open ] || continue

  title=$(printf '%s' "$issue" | j -r '.title')
  url=$(printf '%s' "$issue" | j -r '.html_url')
  comment=$(printf '%s' "$comments" | j -s -r --argjson id "$id" 'add // [] | map(select(.id == $id)) | .[0]')
  body=$(printf '%s' "$comment" | j -r '.body // ""')
  link=$(printf '%s' "$comment" | j -r '.html_url // empty')
  case "$kind" in
    budget-daily)
      label="하루 상한 멈춤"
      todo="할 일 없음: KST 0시가 지나면 공장이 스스로 다시 돈다."
      # A daily budget of 0 (`상한 $0` in the ledger comment) is a stop on purpose: midnight does not
      # start the factory again (#502). The ledger's own midnight sentence is dropped from the quote.
      if printf '%s' "$body" | grep -qE '상한 \$0(\.0*)?([^0-9.]|$)'; then
        label="하루 상한 0(멈춤)"
        todo="상한 0: 일부러 멈춘 상태다. 다시 켜려면 하루 상한(FACTORY_DAILY_BUDGET_USD)을 올린다."
        body=$(printf '%s\n' "$body" | sed 's/ *KST 0시가 지나면 예약 실행이 다시 시작한다\.//')
      fi ;;
    queue-empty)
      label="spec 큐 바닥남"
      todo="다음 spec을 FACTORY_SPEC_QUEUE에 넣는다(조율자 몫)." ;;
    idle)
      label="공장 idle"
      todo="FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다(조율자 몫)." ;;
    stalled)
      label="공장 막힘"
      todo="위 사람 몫 이슈를 풀고 ready-for-human을 뗀다."
      # Once per pair (dispatch-next.sh): a deferred issue blocks a waiting ticket (#437).
      case "$value" in deferred-*)
        label="공장 막힘(미룸)"
        todo="막힌 티켓도 미룰 것이면 deferred를 붙이고, 아니면 미룬 이슈의 막음을 푼다." ;;
      esac ;;
    bench-regression)
      label="벤치 한도 초과"
      todo="위 커밋 구간에서 한도를 넘긴 커밋을 찾아 고칠 티켓을 낸다(조율자 몫)." ;;
    human-check)
      label="사람 확인"
      todo=$human_check_todo ;;
  esac
  text="종류: $label
이슈: $url
제목: #$n $title
댓글: ${link:-$url}

$body

할 일: $todo"
  subject="[$NAME 공장] $label: #$n $title"
  while IFS= read -r to; do
    [ -n "$to" ] || continue
    if [ "$kind" = idle ]; then line="idle $value $to"
    elif [ "$to" = "$TO_COORD" ]; then line=$id
    else line="$id $to"; fi
    if $seed; then remember "$line"; continue; fi
    if send "$to" "$subject" "$text"; then
      remember "$line"
      echo "bridge: sent $kind #$n to $to (comment $id)"
    else
      echo "bridge: could not send $kind #$n to $to (comment $id); will retry" >&2
      failed=1
    fi
  done <<< "$pending"
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
    deliver "idle $queue" "$coord_and_cc" \
      "[$NAME 공장] 공장 idle: 큐 $queue 끝" "$text" "idle ($queue)"
  fi
fi

if $seed; then echo "bridge: seeded $(wc -l < "$SENT" | tr -d ' ') lines"; fi
exit "$failed"
