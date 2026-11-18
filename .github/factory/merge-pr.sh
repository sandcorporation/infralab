#!/usr/bin/env bash
# Sourced by verify.sh and odin.sh (#172): the factory merges a PR the way a local worker does, with
# scripts/pr-merge.sh — wait until ci.yml's required jobs are registered and green, then squash-merge
# that head — but the merge call goes out with the factory App's token (FACTORY_APP_TOKEN).
#
# The App's merge is a push to main as the App: release.yml runs on that push, and GitHub closes the
# ticket through `Closes #N` (an `issues: closed` event the Implementer's frontier job ignores, since
# Verify moves the chain on itself). The main ruleset requires the same checks, so a merge before
# they are green is refused by GitHub, not only by the script.
#
#   factory_merge <PR>   0 merged
#                        1 GitHub refused the merge three times (mergeability not computed yet, the
#                          head moved, a conflict): the caller's conflict / retry path
#                        2 the checks are red, did not finish or did not register, the PR is not open,
#                          or FACTORY_APP_TOKEN is missing: nothing to retry
#
# Environment: REPO, GH_TOKEN (reads the checks), FACTORY_APP_TOKEN (the merge call);
# FACTORY_PR_MERGE (command run with the PR instead of scripts/pr-merge.sh, tests; same exit codes);
# FACTORY_MERGE_WAIT (seconds between attempts, default 15).
factory_merge() {
  local pr=$1 attempt rc script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/pr-merge.sh"
  for attempt in 1 2 3; do
    if [ -n "${FACTORY_PR_MERGE:-}" ]; then
      $FACTORY_PR_MERGE "$pr"
    elif [ -z "${FACTORY_APP_TOKEN:-}" ]; then
      echo "::error::FACTORY_APP_TOKEN is not set; the factory merges only as its App (#172)"
      return 2
    else
      PR_MERGE_REPO=$REPO PR_MERGE_TOKEN=$FACTORY_APP_TOKEN bash "$script" "$pr"
    fi
    rc=$?
    case $rc in
      0) return 0 ;;
      5) echo "::notice::merge attempt $attempt of PR #$pr refused; GitHub may still be computing mergeability" ;;
      *) echo "::error::PR #$pr not merged: scripts/pr-merge.sh exit $rc (checks red, unfinished or unregistered, or the PR is not open)"
         return 2 ;;
    esac
    [ "$attempt" -lt 3 ] && sleep "${FACTORY_MERGE_WAIT:-15}"
  done
  return 1
}
