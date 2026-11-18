#!/usr/bin/env bash
# PR 을 CI 초록일 때만 squash 병합한다(#164). 로컬 작업자(사람·에이전트)의 병합은 이 스크립트로만 —
# .claude/hooks/block-direct-merge.py 가 `gh pr merge`·`gh api .../merge` 직접 호출을 막는다.
#   scripts/pr-merge.sh <PR 번호>
#
# 1. 검사가 등록될 때까지 기다린다(PR_MERGE_REGISTER_WAIT 초, 기본 600). push 직후 목록이 빈 것을
#    「검사 없음 = 통과」로 읽지 않는다(#118).
# 2. 모든 검사가 끝날 때까지 기다린다(PR_MERGE_TOTAL_WAIT 초, 기본 2400). 하나라도 실패로 끝나면 곧바로 멈춘다.
# 3. ci.yml 필수 잡이 모두 SUCCESS 이고 다른 검사에 실패가 없을 때만 병합한다. 병합은 검사를 읽은 그
#    head 커밋에만(--match-head-commit) — 사이에 새 push 가 오면 GitHub 가 병합을 거절한다.
#
# SKIPPED 는 필수 잡에서 실패로 본다: ci.yml 에는 paths 거름도 잡 if: 도 없어서 필수 잡이 건너뛰어졌다면
# 정상 경로가 아니다. 필수 아닌 검사의 SKIPPED·NEUTRAL 은 괜찮다.
#
# 종료 코드: 0 병합함 / 1 검사 실패·필수 잡이 SUCCESS 아님 / 2 사용법 / 3 시간 초과(미등록·안 끝남) /
#            4 PR 이 열려 있지 않음·조회 실패 / 5 gh pr merge 실패
set -uo pipefail

REQUIRED=(backend web agent exam-proxy-route factory)
REQUIRED_WORKFLOW=ci

pr="${1:-}"
case "$pr" in ''|*[!0-9]*) echo "사용법: scripts/pr-merge.sh <PR 번호>" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "pr-merge: jq 가 필요합니다" >&2; exit 2; }

register_wait="${PR_MERGE_REGISTER_WAIT:-600}"
total_wait="${PR_MERGE_TOTAL_WAIT:-2400}"
poll="${PR_MERGE_POLL:-20}"
required_json="$(printf '%s\n' "${REQUIRED[@]}" | jq -R . | jq -cs .)"
start=$SECONDS

# 검사 한 줄 모양: 이름<TAB>상태<TAB>링크. CheckRun 은 status·conclusion, StatusContext(외부 CI)는 state.
# 상태는 PENDING / SUCCESS / SKIPPED / NEUTRAL / 그 밖(실패: FAILURE·CANCELLED·TIMED_OUT·ERROR …).
# shellcheck disable=SC2016
JQ_ROWS='
  .statusCheckRollup // []
  | map(if .__typename == "StatusContext" then
          {name: .context, wf: "", st: (if .state == "PENDING" or .state == "EXPECTED" then "PENDING" else .state end), link: (.targetUrl // "")}
        else
          {name: .name, wf: (.workflowName // ""), st: (if (.status // "") != "COMPLETED" then "PENDING" else (.conclusion // "PENDING") end), link: (.detailsUrl // "")}
        end)'

while :; do
  elapsed=$((SECONDS - start))
  if ! view="$(gh pr view "$pr" --json state,headRefOid,statusCheckRollup 2>&1)" || ! jq -e . >/dev/null 2>&1 <<<"$view"; then
    echo "pr-merge: PR #$pr 조회 실패: $view" >&2; exit 4
  fi
  state="$(jq -r .state <<<"$view")"
  [ "$state" = OPEN ] || { echo "pr-merge: PR #$pr 이 열려 있지 않다($state) — 병합하지 않는다" >&2; exit 4; }
  head="$(jq -r .headRefOid <<<"$view")"
  rows="$(jq -c "$JQ_ROWS" <<<"$view")"

  # 실패로 끝난 검사가 하나라도 있으면 기다리지 않고 멈춘다.
  failed="$(jq -r 'map(select(.st as $s | ["PENDING","SUCCESS","SKIPPED","NEUTRAL"] | index($s) | not)) | .[] | "  \(.name)  \(.st)  \(.link)"' <<<"$rows")"
  if [ -n "$failed" ]; then
    echo "pr-merge: PR #$pr 실패한 검사 — 병합하지 않는다:" >&2; echo "$failed" >&2; exit 1
  fi

  missing="$(jq -r --argjson req "$required_json" --arg wf "$REQUIRED_WORKFLOW" \
    '. as $r | $req[] | select(. as $n | $r | map(select(.name == $n and .wf == $wf)) | length == 0)' <<<"$rows")"
  pending="$(jq -r 'map(select(.st == "PENDING")) | .[].name' <<<"$rows")"

  if [ -z "$missing" ] && [ -z "$pending" ]; then
    break
  fi
  if [ -n "$missing" ] && [ "$elapsed" -ge "$register_wait" ]; then
    echo "pr-merge: PR #$pr 필수 검사가 ${register_wait}초 안에 등록되지 않았다 — 병합하지 않는다:" $missing >&2; exit 3
  fi
  if [ "$elapsed" -ge "$total_wait" ]; then
    echo "pr-merge: PR #$pr 검사가 ${total_wait}초 안에 끝나지 않았다 — 병합하지 않는다. 남은 것:" $missing $pending >&2; exit 3
  fi
  echo "pr-merge: #$pr 기다림(${elapsed}s) — 미등록: ${missing//$'\n'/ } / 진행 중: ${pending//$'\n'/ }"
  sleep "$poll"
done

# 모두 끝났다. 필수 잡은 SUCCESS 만(SKIPPED 도 안 된다 — 머리말).
notok="$(jq -r --argjson req "$required_json" --arg wf "$REQUIRED_WORKFLOW" \
  '.[] | select(.wf == $wf and (.name as $n | $req | index($n)) and .st != "SUCCESS") | "  \(.name)  \(.st)  \(.link)"' <<<"$rows")"
if [ -n "$notok" ]; then
  echo "pr-merge: PR #$pr 필수 잡이 SUCCESS 가 아니다 — 병합하지 않는다:" >&2; echo "$notok" >&2; exit 1
fi

echo "pr-merge: #$pr 검사 모두 초록(head $head) — squash 병합"
if ! gh pr merge "$pr" --squash --delete-branch --match-head-commit "$head"; then
  # 워크트리에서는 병합 뒤 로컬 브랜치 정리(main checkout)만 실패할 수 있다 — 병합 여부는 PR 상태로 본다.
  if [ "$(gh pr view "$pr" --json state 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" = MERGED ]; then
    echo "pr-merge: 병합됨(로컬 브랜치 정리는 실패 — 직접 지운다)" >&2; exit 0
  fi
  echo "pr-merge: gh pr merge 실패" >&2; exit 5
fi
