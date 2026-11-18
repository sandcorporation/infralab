#!/usr/bin/env bash
# 공개 주소 <도메인>/exam-proxy → web(nginx) → proxy 경로 시험(#82). 도커만 있으면 된다.
#   bash scripts/check_exam_proxy_route.sh
# 운영 web/nginx.conf 를 그대로 붙인 nginx 와 진짜 proxy(가짜 공급사 모드), 가짜 backend(scripts/exam_proxy_route/)를 띄워
# SDK 가 base URL 뒤에 붙이는 경로를 curl 로 부른다:
#   Anthropic SDK·Claude Code  ANTHROPIC_BASE_URL=<도메인>/exam-proxy/anthropic → …/v1/messages
#   OpenAI SDK·Codex           base_url=<도메인>/exam-proxy/openai/v1           → …/chat/completions, …/responses
# 보는 것: 접두어 제거·쿼리 유지, 스트리밍 조각, 토큰 없음·틀림 401, 본문 한도 413, IP·토큰 한도 429,
# client_id = X-Forwarded-For 끝 주소, proxy 가 없는 compose 에서도 nginx 가 뜬다.
set -uo pipefail
cd "$(dirname "$0")/exam_proxy_route" || exit 1
project="infralab-exam-proxy-route-$$"
dc() { docker compose -p "$project" "$@"; }
trap 'dc --profile proxy down -v --remove-orphans >/dev/null 2>&1' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "실패: $*"; }
expect_status() { # <이름> <기대> <curl 인자...>
  local name=$1 want=$2
  shift 2
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@")
  if [ "$got" = "$want" ]; then ok; else bad "$name: $got(기대 $want)"; fi
}

echo "== proxy 없이 web 만"
dc up -d --wait web backend >/dev/null 2>&1 || { echo "web 이 proxy 없이 뜨지 않는다"; dc logs web | tail -20; exit 1; }
base="http://$(dc port web 8080)"
expect_status 'proxy 없음 → 502' 502 "$base/exam-proxy/healthz"

echo "== web + proxy"
dc --profile proxy up -d --build --wait >/dev/null 2>&1 || { echo "proxy 가 뜨지 않는다"; dc --profile proxy logs | tail -30; exit 1; }
base="http://$(dc port web 8080)"
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/exam-proxy/healthz")" = 200 ] && break
  sleep 1
done
expect_status 'healthz' 200 "$base/exam-proxy/healthz"
expect_status '모르는 경로 404' 404 -X POST "$base/exam-proxy/v1/messages" -d '{}'
expect_status '/providers 는 공개 길에 없다' 404 "$base/exam-proxy/providers" -H 'Authorization: Bearer anything'
expect_status '/providers? 쿼리 붙여도 404' 404 "$base/exam-proxy/providers?x=1"

A="$base/exam-proxy/anthropic"
O="$base/exam-proxy/openai/v1"
json=(-H 'Content-Type: application/json')
expect_status 'anthropic 토큰 없음' 401 -X POST "$A/v1/messages" "${json[@]}" -d '{"model":"m","max_tokens":5,"messages":[]}'
expect_status 'anthropic 틀린 토큰' 401 -X POST "$A/v1/messages" "${json[@]}" -H 'x-api-key: nope' -d '{"model":"m"}'
expect_status 'openai 토큰 없음' 401 -X POST "$O/chat/completions" "${json[@]}" -d '{"model":"m"}'
expect_status 'openai 틀린 토큰' 401 -X POST "$O/responses" "${json[@]}" -H 'Authorization: Bearer nope' -d '{"model":"m"}'

out=$(curl -s --max-time 20 -X POST "$A/v1/messages?beta=true" "${json[@]}" -H 'x-api-key: tok-ok' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}')
if [[ "$out" == *'infralab fake provider reply.'* ]]; then ok; else bad "anthropic /v1/messages?beta=true: $out"; fi
out=$(curl -s --max-time 20 -X POST "$O/chat/completions" "${json[@]}" -H 'Authorization: Bearer tok-ok' \
  -d '{"model":"m","messages":[{"role":"user","content":"hi"}]}')
if [[ "$out" == *'infralab fake provider reply.'* ]]; then ok; else bad "openai /chat/completions: $out"; fi
out=$(curl -s --max-time 20 -X POST "$O/responses" "${json[@]}" -H 'Authorization: Bearer tok-ok' -d '{"model":"m","input":"hi"}')
if [[ "$out" == *'infralab fake provider reply.'* ]]; then ok; else bad "openai /responses: $out"; fi

# 스트리밍: SSE 사건이 nginx 를 지나 그대로 온다.
out=$(curl -sN --max-time 20 -X POST "$A/v1/messages" "${json[@]}" -H 'Authorization: Bearer tok-ok' \
  -d '{"model":"m","max_tokens":5,"stream":true,"messages":[{"role":"user","content":"hi"}]}')
if [[ "$out" == *'event: message_stop'* ]]; then ok; else bad "anthropic 스트리밍: ${out:0:300}"; fi
out=$(curl -sN --max-time 20 -X POST "$O/responses" "${json[@]}" -H 'Authorization: Bearer tok-ok' -d '{"model":"m","input":"hi","stream":true}')
if [[ "$out" == *'response.completed'* ]]; then ok; else bad "openai responses 스트리밍: ${out:0:300}"; fi

# client_id = 바깥 프록시가 끝에 붙인 주소(지원자가 꾸민 앞쪽 값이 아니다).
curl -s -o /dev/null --max-time 20 -X POST "$O/chat/completions" "${json[@]}" -H 'Authorization: Bearer tok-ok' \
  -H 'X-Forwarded-For: 198.51.100.66, 203.0.113.9' -d '{"model":"m","messages":[]}'
last=$(dc exec -T backend python -c 'import urllib.request as u; print(u.urlopen("http://127.0.0.1:8000/last").read().decode())')
if [[ "$last" == *'"client_id": "203.0.113.9"'* ]]; then ok; else bad "client_id: $last"; fi

# 본문 한도(nginx client_max_body_size 32m — proxy 와 같다).
head -c $((33 * 1024 * 1024)) /dev/zero | tr '\0' 'a' > "${TMPDIR:-/tmp}/$project.body"
expect_status '본문 33 MiB → 413' 413 -X POST "$A/v1/messages" "${json[@]}" -H 'x-api-key: tok-ok' --data-binary "@${TMPDIR:-/tmp}/$project.body"
rm -f "${TMPDIR:-/tmp}/$project.body"

# 토큰 한도(이 compose 는 burst 30, 분당 1): 같은 토큰 31번째부터 429, 다른 토큰은 받는다.
codes=$(for _ in $(seq 1 31); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 -X POST "$O/chat/completions" "${json[@]}" -H 'Authorization: Bearer tok-ok-burst' -d '{"model":"m","messages":[]}'
done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
if [[ "$codes" == *' 30 200;'* && "$codes" == *' 1 429;'* ]]; then ok; else bad "토큰 한도: $codes"; fi
expect_status '다른 토큰은 그대로' 200 -X POST "$O/chat/completions" "${json[@]}" -H 'Authorization: Bearer tok-ok-other' -d '{"model":"m","messages":[]}'

# IP 한도(20r/s, burst 200): 한꺼번에 400번이면 429 가 섞인다. 다른 IP(X-Forwarded-For 끝)는 막히지 않는다.
codes=$(seq 1 400 | xargs -P 50 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 -H 'X-Forwarded-For: 192.0.2.1' "$base/exam-proxy/healthz" | sort | uniq -c | tr -s ' ' | tr '\n' ';')
if [[ "$codes" == *' 429;'* ]]; then ok; else bad "IP 한도: $codes"; fi
expect_status '다른 IP 는 그대로' 200 -H 'X-Forwarded-For: 192.0.2.2' "$base/exam-proxy/healthz"

echo "exam proxy 경로 시험: 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
