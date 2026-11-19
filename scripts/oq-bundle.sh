#!/usr/bin/env bash
# spec 이슈의 Open Questions 절을 꺼낸다(#248). 조율자가 질문을 묶어 대장에게 올릴 때 쓴다.
#   scripts/oq-bundle.sh <spec 이슈 번호>
#
# - spec 에 `deferred` 라벨이 있으면 묶기를 거절한다. 대표가 「나중」으로 미룬 spec 의 질문이 대표에게
#   가지 않게 하는 문이다(#236 의 질문 10개가 그렇게 갔다). stdout 은 비운다.
# - 없으면 본문의 Open Questions 절(그 제목부터 다음 같은 단계 이상의 제목 앞까지)을 stdout 에 낸다.
#   코드 울타리(``` · ~~~) 안의 `#` 줄은 제목으로 보지 않는다.
# - 저장소는 FACTORY_REPO(owner/name)가 있으면 그것, 없으면 gh 가 고르는 현재 저장소.
#
# 종료 코드: 0 절을 냄 / 1 deferred 라 거절 / 2 사용법·도구 없음 / 3 Open Questions 절 없음 / 4 이슈 조회 실패
set -uo pipefail

issue="${1:-}"
case "$issue" in ''|*[!0-9]*) echo "사용법: scripts/oq-bundle.sh <spec 이슈 번호>" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "oq-bundle: jq 가 필요합니다" >&2; exit 2; }

repo_args=()
[ -n "${FACTORY_REPO:-}" ] && repo_args=(--repo "$FACTORY_REPO")

if ! view="$(gh issue view "$issue" ${repo_args[@]+"${repo_args[@]}"} --json labels,body 2>&1)" \
   || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$view"; then
  echo "oq-bundle: 이슈 #$issue 를 읽지 못했습니다: $view" >&2
  exit 4
fi

if jq -e '[.labels[]?.name] | index("deferred")' >/dev/null <<<"$view"; then
  echo "oq-bundle: #$issue 는 deferred spec 입니다 — 질문을 묶지 않습니다(시기부터 대장에게)" >&2
  exit 1
fi

section="$(jq -r '.body // ""' <<<"$view" | tr -d '\r' | awk '
  /^[[:space:]]*(```|~~~)/ { fence = !fence }
  !fence && /^#+[[:space:]]/ {
    match($0, /^#+/); level = RLENGTH
    if (on && level <= start) exit
    title = tolower(substr($0, level + 1)); gsub(/^[[:space:]]+|[[:space:]#]+$/, "", title)
    if (!on && title ~ /^open questions?$/) { on = 1; start = level }
  }
  on { print }
')"

if [ -z "$section" ]; then
  echo "oq-bundle: #$issue 본문에 Open Questions 절이 없습니다" >&2
  exit 3
fi
printf '%s\n' "$section"
