#!/bin/bash
# 사용: serve-and-curl.sh <시작 명령> <포트> <경로> [기대 문자열]
# 프로젝트(/work/app, APP_DIR 로 바꿀 수 있다)에서 시작 명령을 백그라운드로 띄우고(환경변수 PORT=<포트>),
# 응답할 때까지(최대 30초) 기다렸다가 http://127.0.0.1:<포트><경로> 를 curl 해 본문을 출력하고 앱을 끈다.
# 기대 문자열이 있으면 본문에 없을 때 비정상 종료한다. 학생이 앱을 켜 둔 상태에 기대지 않는다 —
# 같은 포트에 이미 응답하는 것이 있으면 시작하지 않고 실패한다.
set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "사용: serve-and-curl.sh <시작 명령> <포트> <경로> [기대 문자열]" >&2
  exit 2
fi
start=$1
port=$2
path=$3
want=${4:-}
app=${APP_DIR:-/work/app}
url="http://127.0.0.1:$port$path"

if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/"; then
  echo "포트 $port 를 이미 쓰는 프로세스가 있다 — 끄고 다시 채점한다" >&2
  exit 1
fi

log=$(mktemp)
cd "$app" || { echo "프로젝트 폴더가 없다: $app" >&2; exit 1; }
PORT=$port setsid bash -c "exec $start" > "$log" 2>&1 &
pid=$!
cleanup() {
  kill -TERM -- "-$pid" 2> /dev/null || kill -TERM "$pid" 2> /dev/null
  sleep 0.5
  kill -KILL -- "-$pid" 2> /dev/null || true
  rm -f "$log"
}
trap cleanup EXIT

body=
for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2> /dev/null; then
    echo "앱이 바로 끝났다:" >&2
    tail -n 20 "$log" >&2
    exit 1
  fi
  if body=$(curl -sf -m 2 "$url"); then
    break
  fi
  body=
  sleep 0.5
done

if [ -z "$body" ]; then
  echo "30초 안에 $url 이 응답하지 않았다. 앱 출력:" >&2
  tail -n 20 "$log" >&2
  exit 1
fi
printf '%s\n' "$body" | head -c 500
if [ -n "$want" ] && ! printf '%s' "$body" | grep -qF -- "$want"; then
  echo "응답에 '$want' 가 없다" >&2
  exit 1
fi
