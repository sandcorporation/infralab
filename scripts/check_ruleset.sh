#!/usr/bin/env bash
# 필수 검사 목록 드리프트(#183): main ruleset 의 필수 검사 == scripts/pr-merge.sh REQUIRED, 우회자 0.
#   scripts/check_ruleset.sh            release.yml 의 ruleset 잡(main push)과 로컬에서 돈다.
# 환경: RULESET_ID(기본 27560028), REPO(기본 GITHUB_REPOSITORY, 없으면 sandcorporation/infralab), GH_TOKEN.
# bypass_actors 는 ruleset 을 고칠 수 있는 토큰에만 보인다 — Actions GITHUB_TOKEN 에는 빠져 오므로 그때는
# 우회자를 「확인 못 함」으로 알리고 필수 검사만 본다. 관리자 토큰(로컬 gh)이면 우회자 0 까지 본다.
set -euo pipefail
cd "$(dirname "$0")/.."
id=${RULESET_ID:-27560028}
repo=${REPO:-${GITHUB_REPOSITORY:-sandcorporation/infralab}}

rs=$(gh api "repos/$repo/rulesets/$id") || { echo "check_ruleset: ruleset $id 를 읽지 못함" >&2; exit 1; }
required=$(sed -n 's/^REQUIRED=(\(.*\))[[:space:]]*$/\1/p' scripts/pr-merge.sh | tr ' ' '\n' | sed '/^$/d' | sort)
contexts=$(printf '%s' "$rs" | jq -r '[.rules[] | select(.type == "required_status_checks")
  | .parameters.required_status_checks[].context] | .[]' | tr -d '\r' | sort)
bad=0
if [ "$(printf '%s' "$rs" | jq -r '.enforcement' | tr -d '\r')" != active ]; then
  echo "check_ruleset: ruleset $id 이 active 가 아니다" >&2; bad=1
fi
if [ "$contexts" != "$required" ]; then
  echo "check_ruleset: ruleset $id 필수 검사와 pr-merge.sh REQUIRED 가 다르다" >&2
  diff <(printf '%s\n' "$contexts") <(printf '%s\n' "$required") | sed 's/^</  ruleset 에만:/; s/^>/  REQUIRED 에만:/' | grep '에만' >&2
  bad=1
fi
case "$(printf '%s' "$rs" | jq -r 'if has("bypass_actors") then (.bypass_actors | length | tostring) else "hidden" end' | tr -d '\r')" in
  0) echo "check_ruleset: 우회자 0" ;;
  hidden) echo "::notice::check_ruleset: 이 토큰에는 ruleset $id 의 우회자가 보이지 않는다 — 우회자 0 은 관리자 토큰으로 로컬에서 확인" ;;
  *) echo "check_ruleset: ruleset $id 에 우회자가 있다" >&2; bad=1 ;;
esac
[ "$bad" -eq 0 ] || exit 1
echo "check_ruleset: ruleset $id 필수 검사 == pr-merge.sh REQUIRED ($(printf '%s' "$required" | tr '\n' ' '))"
