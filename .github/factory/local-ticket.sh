#!/usr/bin/env bash
# A ticket that changes `.github/workflows/` or `.claude/` is not for the factory (ADR-0001, "workflow 파일은
# 사람 몫"): the factory's push token (its App, #172) has no `workflows` permission, and the factory's
# agent (Claude Code) is refused every edit under `.claude/` as a sensitive file (#166, run 44331695750:
# three failed runs). A local worker takes it.
#
#   local-ticket.sh <issue>
#
# A ticket is local when it carries the `local` label or its body carries the marker
# `<!-- factory-touches-workflows -->` or `<!-- factory-touches-claude -->` (Decompose writes them into a
# ticket that will change workflow files or `.claude/`) or a checked template line `- [x] workflow 파일을
# 바꾼다` / `- [x] .claude/ 를 바꾼다` (a hand-written ticket). Merely mentioning
# `.github/workflows` ("건드리지 않는다") does not count (#66); `workflow-guard.sh` still stops a push.
# A local ticket gets `local` (adding a label creates it when missing) and, unless it is already with a
# person, is handed over by hand-to-human.sh (`ready-for-human`, no `ready-for-agent`, one comment
# `<!-- factory-human -->` whose next line is `<!-- factory-local -->`; #192).
# Writes local=true|false to $GITHUB_OUTPUT (stdout when unset); exits 0 unless it cannot read the issue.
# decompose.sh (right after Decompose), odin.sh (before approving) and factory-implementer.yml (the
# `approved` job and the claim) call it, so a ticket that slipped past Decompose is turned around there.
#
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
n=${1:?usage: local-ticket.sh <issue>}
here=$(cd "$(dirname "$0")" && pwd)

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; else printf '%s\n' "$@"; fi
}

read -r mentions labels < <(gh api "repos/$REPO/issues/$n" --jq '[
  ((.body // "") | test("<!--\\s*factory-touches-(workflows|claude)\\s*-->|(^|\\n)\\s*[-*]\\s*\\[[xX]\\]\\s*(workflow 파일을|\\.claude/ 를) 바꾼") | tostring),
  ([.labels[].name] | join(","))] | @tsv' | tr -d '\r') \
  || { echo "::error::local-ticket: could not read #$n"; exit 1; }
labels=",${labels:-},"
case "$labels" in
  *,local,*) is_local=true ;;
  *) is_local=$mentions ;;
esac
if [ "$is_local" != true ]; then output local=false; exit 0; fi

case "$labels" in *,local,*) ;; *)
  gh api "repos/$REPO/issues/$n/labels" -f "labels[]=local" > /dev/null \
    || echo "::warning::local-ticket: could not add local to #$n" ;;
esac
# hand-to-human.sh takes ready-for-agent off and leaves the marker; once. The code says why (#238,
# facet#437): a ticket that names `.github/workflows/` or `.claude/` cannot be done by the factory
# (workflow-change); one that is only labelled `local` needs a person's decision, secret or machine
# (local-only).
case "$labels" in *,ready-for-human,*) ;; *)
  if [ "$mentions" = true ]; then
    code=workflow-change
    why='workflow·`.claude/` 파일 — 로컬 작업자 몫. 이 티켓은 `.github/workflows/` 나 `.claude/` 를 건드린다: 공장의 push 토큰(App)에는 workflows 권한이 없고, 공장 에이전트(Claude Code)는 `.claude/` 아래 파일을 고치지 못한다(민감 파일 거부, #166). `local` 로 공장 밖에 두고 사람(로컬 작업자)에게 넘긴다.'
  else
    code=local-only
    why='사람 몫 — 사람의 결정·비밀값·사람 기계가 필요한 티켓. `local` 로 공장 밖에 두고 사람에게 넘긴다.'
  fi
  bash "$here/hand-to-human.sh" "$n" "$code" "<!-- factory-local -->
$why" > /dev/null \
    || echo "::warning::local-ticket: could not hand #$n to a human" ;;
esac
output local=true
