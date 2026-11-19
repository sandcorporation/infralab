#!/usr/bin/env bash
# The one way the factory hands an issue to a person (ADR-0001, "사람 넘김", #410).
#
#   hand-to-human.sh <issue> <code> <reason>
#
# Takes `in-progress` and `ready-for-agent` off the issue (when present), adds `ready-for-human` and
# leaves one comment: the marker line `<!-- factory-human <code> -->`, then <reason>. The mail bridge
# (bridge.sh) mails that marker to the managing session, with the code in the subject and the first
# line (#437). Every factory path that hands an issue to a person calls this script, and no other
# factory file adds that label (tests/hand-to-human.sh checks it): a hand-over without the marker
# reaches nobody (#410: #321 waited a day unnoticed).
#
# <code> says why (#437); any other word is a usage error (exit 2):
#
#   conflict               the branch conflicts with main and the factory's own merge did not help
#                          (merge-check.sh in Finish merge / Require main merged ran first, #434)
#   acceptance-unpassable  the acceptance test cannot pass as written (acceptance-probe.sh ran first, #414)
#   push-rejected          the push was refused and catching up with main did not help (workflow-guard.sh
#                          push-retry ran first, #417)
#   attempts-exhausted     the ticket failed its limit of times
#   agent-blocked          the Implementer said it is blocked, or stopped with a reason and no commit
#   workflow-change        the ticket names `.github/workflows/`, which the factory token cannot push
#                          (local-ticket.sh)
#   local-only             the ticket is labelled `local` without naming a workflow: it needs a person's
#                          decision, secret or machine (local-ticket.sh)
#   spec-merge-failed      Odin could not merge the spec PR
#   other                  anything else; the bridge counts an old marker without a code as this
#
# Each hand-over also goes on the ledger as `event=handover issue=#<n> code=<code>` (ledger.sh event,
# best-effort: no ledger is not a failure), so `ledger.sh stats` counts hand-overs per code.
#
# A person puts the issue back into the factory by taking `ready-for-human` off, adding
# `ready-for-agent` and commenting a line starting with `<!-- factory-reset -->`: failures and
# send-backs before that comment no longer count (factory-implementer.yml, verify.sh).
#
# A person puts an issue off instead (#437) by taking `ready-for-human` off, adding `deferred` and
# commenting the decision (why, until when). A deferred issue stays open but waits for nobody: the bridge
# does not mail it, dispatch-next.sh does not count it as a person's blocker (it says once that it blocks
# a waiting ticket) and a spec whose only open tickets are deferred closes, naming them.
#
# Exits 0 when the label and the comment are there, 1 when either call failed (the others only warn).
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
CODES='conflict acceptance-unpassable push-rejected attempts-exhausted agent-blocked workflow-change local-only spec-merge-failed other'
usage() { echo "usage: hand-to-human.sh <issue> <code> <reason>  (code: ${CODES// /, })" >&2; exit 2; }
[ $# -eq 3 ] || usage
n=$1 code=$2 reason=$3
case "$n" in '' | *[!0-9]*) usage ;; esac
case " $CODES " in *" $code "*) ;; *) echo "hand-to-human: unknown code [$code]" >&2; usage ;; esac
[ -n "$reason" ] || usage
here=$(cd "$(dirname "$0")" && pwd)
HUMAN="<!-- factory-human $code -->"
LABEL=ready-for-human

labels=$(gh api "repos/$REPO/issues/$n" --jq '[.labels[].name] | join(",")' | tr -d '\r') \
  || { echo "::warning::hand-to-human: could not read the labels of #$n"; labels=; }
# A deferred issue was put off by a person: every caller (local-ticket, odin, decompose, implementer,
# verify) leaves it as it is instead of putting ready-for-human back (#473).
case ",$labels," in *,deferred,*)
  echo "::warning::hand-to-human: #$n is deferred; not handing it over ($code)"
  exit 0 ;;
esac
# Handed over once already with this code, and a person since took ready-for-human off without putting
# the issue back in the factory (no ready-for-agent, no in-progress): they have it. Handing it over again
# would put the label back and mail the same reason again (#473).
case ",$labels," in *,ready-for-human,* | *,ready-for-agent,* | *,in-progress,*) ;; *)
  said=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    | jq -rs --arg m "$HUMAN" '[.[][] | select(.body | startswith($m))] | length' | tr -d '\r') || said=0
  if [ "${said:-0}" -gt 0 ] 2> /dev/null; then
    echo "::warning::hand-to-human: #$n was already handed over ($code) and a person took $LABEL off; leaving it"
    exit 0
  fi ;;
esac
for l in in-progress ready-for-agent; do
  case ",$labels," in *",$l,"*)
    gh api -X DELETE "repos/$REPO/issues/$n/labels/$l" > /dev/null \
      || echo "::warning::hand-to-human: could not take $l off #$n" ;;
  esac
done
status=0
gh api "repos/$REPO/issues/$n/labels" -f "labels[]=$LABEL" > /dev/null \
  || { echo "::warning::hand-to-human: could not add $LABEL to #$n"; status=1; }
gh api "repos/$REPO/issues/$n/comments" -f "body=$HUMAN
$reason" > /dev/null \
  || { echo "::warning::hand-to-human: could not comment on #$n"; status=1; }
bash "$here/ledger.sh" event handover "$n" "code=$code" > /dev/null 2>&1 || true
echo "#$n: handed to a human ($code)"
exit $status
