#!/usr/bin/env bash
# `git push` with the factory GitHub App's installation token (#172) instead of the checkout's GITHUB_TOKEN.
#
#   app-push.sh <git push arguments…>
#
# A GITHUB_TOKEN push wakes no workflow (GitHub's loop guard), so ci.yml never ran on a factory PR and
# main could not require its checks. The App's push fires `pull_request: synchronize`, ci.yml runs on
# the head, and the main ruleset's required checks gate the merge.
#
# actions/checkout leaves GITHUB_TOKEN as `http.https://github.com/.extraheader`. An empty value on the
# command line resets that list (git-config(1), http.extraHeader), so only the App's header goes out.
#
# Environment: FACTORY_APP_TOKEN (actions/create-github-app-token output). Missing: exit 1 without
# pushing — falling back to GITHUB_TOKEN would bring back the PR without checks.
set -u
if [ -z "${FACTORY_APP_TOKEN:-}" ]; then
  echo "::error::FACTORY_APP_TOKEN is not set; not pushing with GITHUB_TOKEN (ci.yml would not run)" >&2
  exit 1
fi
auth=$(printf 'x-access-token:%s' "$FACTORY_APP_TOKEN" | base64 | tr -d '\n')
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$auth"
key=http.https://github.com/.extraheader
exec git -c "$key=" -c "$key=AUTHORIZATION: basic $auth" push "$@"
