#!/usr/bin/env bash
# Delete the useless `ci.yml` pull_request runs of a factory PR branch.
#
#   prune-runs.sh <branch>     delete every ci.yml run of <branch> whose event is pull_request,
#                              whose triggering actor is github-actions[bot] and that has no job.
#                              A run that cannot be deleted is cancelled instead. Never fails.
#
# The factory opens its PRs (spec PRs factory/spec-<S>, Implementer PRs agent/issue-<N>) with
# GITHUB_TOKEN. GitHub then creates the pull_request run of ci.yml waiting for approval
# (conclusion action_required) and turns it into a failure when the PR is merged or closed: a run
# with no job that leaves a red mark on the PR and the commit. The factory never waits for it (the
# Implementer and Verify run `scripts/ci.sh all` themselves, and Odin and Verify dispatch ci.yml on main
# after merging), so odin.sh and verify.sh call this after merging or closing the PR.
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN. Needs bash, gh and jq.
set -u
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
: "${REPO:?REPO is not set}"
branch=${1:?usage: prune-runs.sh <branch>}
BOT='github-actions[bot]'

j() { jq "$@" | tr -d '\r'; }

runs=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?event=pull_request&branch=$branch&per_page=100" 2>/dev/null \
  | j -r --arg b "$branch" --arg bot "$BOT" \
    '.workflow_runs[]? | select(.event == "pull_request" and .head_branch == $b
      and (.triggering_actor.login // .actor.login) == $bot) | .id') || {
  echo "::warning::could not list the ci.yml runs of $branch"
  exit 0
}

deleted=0
for id in $runs; do
  jobs=$(gh api "repos/$REPO/actions/runs/$id/jobs" 2>/dev/null | j -r '.total_count // empty')
  [ "$jobs" = 0 ] || continue
  if gh api -X DELETE "repos/$REPO/actions/runs/$id" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  elif gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1; then
    echo "::warning::could not delete ci.yml run $id of $branch; cancelled it"
  else
    echo "::warning::could not delete or cancel ci.yml run $id of $branch"
  fi
done
echo "pruned $deleted ci.yml pull_request run(s) of $branch"
exit 0
