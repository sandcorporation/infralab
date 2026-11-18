#!/usr/bin/env bash
# workstation 이미지 실행 시험(#125 → #168). 정적 확인(check_workstation_env_test.sh)과 달리 컨테이너를 실제로 띄운다:
# 에이전트 터미널과 같은 길(docker exec … bash -l)로 root 인지, IS_SANDBOX=1 이 보이는지, 그리고 root 에서
# `claude --dangerously-skip-permissions` 가 root 거부 문구 없이 끝나는지. 네트워크는 끊는다 — 로그인이 없어
# 「Not logged in」·연결 오류로 끝나는 것은 정상이고, 거부 문구(root/sudo)만 실패다.
#   check_workstation_image.sh <이미지>      이미 있는(또는 받을 수 있는) 이미지
#   check_workstation_image.sh --build       docker/workstation 을 지금 빌드해서
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --build ]; then
  image=infralab-e2e/workstation:check
  docker build -q -t "$image" docker/workstation >/dev/null
else
  image="${1:?사용법: check_workstation_image.sh <이미지>|--build}"
fi
name="infralab-ws-check-$$"
docker run -d --rm --network none --name "$name" "$image" >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
sh_l() { docker exec "$name" bash -lc "$1"; }
fail=0
uid="$(sh_l 'id -u')"
[ "$uid" = 0 ] && echo "ok   root(uid 0) 로 돈다" || { echo "FAIL uid=$uid — 시나리오는 root 를 전제한다" >&2; fail=1; }
sandbox="$(sh_l 'printf %s "${IS_SANDBOX:-}"')"
[ "$sandbox" = 1 ] && echo "ok   로그인 셸에서 IS_SANDBOX=1" || { echo "FAIL 로그인 셸의 IS_SANDBOX='$sandbox'" >&2; fail=1; }
out="$(sh_l 'timeout 60 claude --dangerously-skip-permissions -p ok </dev/null 2>&1' || true)"
if grep -q 'root/sudo' <<<"$out"; then
  echo "FAIL root 에서 claude --dangerously-skip-permissions 가 거부됐다:" >&2
  head -5 <<<"$out" >&2
  fail=1
else
  echo "ok   claude --dangerously-skip-permissions 가 root 를 거부하지 않는다 ($(head -1 <<<"$out" | cut -c1-80))"
fi
exit "$fail"
