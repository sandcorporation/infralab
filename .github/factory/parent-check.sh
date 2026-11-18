#!/usr/bin/env bash
# `ready-for-agent` needs a parent spec (ADR-0001): the ticket's spec decides its budget, its cost line
# and the tests Verify reads. A ticket with neither a GitHub sub-issue parent nor a "## Parent" section
# does not start: this takes `ready-for-agent` off and says why.
#
#   parent-check.sh <issue> [<sender login>]
#
# Writes ok=true|false to $GITHUB_OUTPUT (stdout when unset); always exits 0 unless it cannot read the
# issue. ok=true when the issue has a parent, is a spec itself (`spec` label: not a ticket), or when the
# label was put on by someone without write permission (public repository: their label is not honoured
# and not answered; a bot sender counts as a writer). A rejected ticket gets a comment starting with
# `<!-- factory-no-parent -->`.
#
# Environment: REPO, GH_TOKEN.
set -u
here=$(cd "$(dirname "$0")" && pwd)
: "${REPO:?REPO is not set}"
n=${1:?usage: parent-check.sh <issue> [<sender login>]}
sender=${2:-}

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; else printf '%s\n' "$@"; fi
}

labels=$(gh api "repos/$REPO/issues/$n" --jq '[.labels[].name] | join(",")' | tr -d '\r') \
  || { echo "::error::parent-check: could not read #$n"; exit 1; }
case ",$labels," in *,spec,*) output ok=true; exit 0 ;; esac

if [ -n "$sender" ]; then
  case "$sender" in
    *'[bot]') ;;
    *)
      perm=$(gh api "repos/$REPO/collaborators/$sender/permission" --jq '.permission' 2>/dev/null | tr -d '\r')
      case "$perm" in
        admin|maintain|write) ;;
        *) echo "::notice::#$n: $sender has no write permission; the label is not checked"; output ok=true; exit 0 ;;
      esac ;;
  esac
fi

p=$(bash "$here/ledger.sh" parent-of "$n" | tr -d '\r')
if [ -n "$p" ]; then output ok=true; exit 0; fi

gh api "repos/$REPO/issues/$n/labels/ready-for-agent" -X DELETE > /dev/null \
  || echo "::warning::parent-check: could not take ready-for-agent off #$n"
gh api "repos/$REPO/issues/$n/comments" -f "body=<!-- factory-no-parent -->
부모 spec 이 없다 — sub-issue 로 묶거나 \`## Parent\` 절을 달라. \`ready-for-agent\` 를 뗐다. 부모를 단 뒤 다시 붙인다." > /dev/null \
  || echo "::warning::parent-check: could not comment on #$n"
output ok=false
