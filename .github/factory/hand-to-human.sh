#!/usr/bin/env bash
# The one way the factory hands an issue to a person (ADR-0001, "사람 넘김", #192).
#
#   hand-to-human.sh <issue> <reason>
#
# Takes `in-progress` and `ready-for-agent` off the issue (when present), leaves one comment (the marker
# line `<!-- factory-human -->`, then <reason>) and then adds `ready-for-human`. The mail bridge
# (bridge.sh) mails the label to the managing session and quotes that comment as the reason; the comment
# goes first so the bridge never sees the label without it. Every factory path that hands an issue to a
# person calls this script, and no other factory file adds that label (tests/hand-to-human.sh checks it):
# one way, one marker (#192; #166 was handed over without one).
#
# A person puts the issue back into the factory by taking `ready-for-human` off, adding
# `ready-for-agent` and commenting a line starting with `<!-- factory-reset -->`: failures and
# send-backs before that comment no longer count (factory-implementer.yml, verify.sh).
#
# Exits 0 when the label and the comment are there, 1 when either call failed (the others only warn).
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
[ $# -eq 2 ] || { echo 'usage: hand-to-human.sh <issue> <reason>' >&2; exit 2; }
n=$1 reason=$2
case "$n" in '' | *[!0-9]*) echo 'usage: hand-to-human.sh <issue> <reason>' >&2; exit 2 ;; esac
HUMAN='<!-- factory-human -->'
LABEL=ready-for-human

labels=$(gh api "repos/$REPO/issues/$n" --jq '[.labels[].name] | join(",")' | tr -d '\r') \
  || { echo "::warning::hand-to-human: could not read the labels of #$n"; labels=; }
for l in in-progress ready-for-agent; do
  case ",$labels," in *",$l,"*)
    gh api -X DELETE "repos/$REPO/issues/$n/labels/$l" > /dev/null \
      || echo "::warning::hand-to-human: could not take $l off #$n" ;;
  esac
done
status=0
gh api "repos/$REPO/issues/$n/comments" -f "body=$HUMAN
$reason" > /dev/null \
  || { echo "::warning::hand-to-human: could not comment on #$n"; status=1; }
gh api "repos/$REPO/issues/$n/labels" -f "labels[]=$LABEL" > /dev/null \
  || { echo "::warning::hand-to-human: could not add $LABEL to #$n"; status=1; }
echo "#$n: handed to a human"
exit $status
