#!/bin/bash
# 인수·호환 검사가 함께 쓰는 함수 — `source app-lib.sh` 로 불러 쓴다.
# start_app <포트>: /work/app 의 FastAPI 앱을 띄우고 /health 가 응답할 때까지(최대 30초) 기다린다. 스크립트가 끝나면 앱을 끈다.
# 학생이 앱을 켜 둔 상태에 기대지 않는다 — 같은 포트에 이미 응답하는 것이 있으면 실패한다.

APP_DIR=${APP_DIR:-/work/app}

start_app() {
  port=$1
  base="http://127.0.0.1:$port"
  if curl -s -m 2 -o /dev/null "$base/"; then
    echo "포트 $port 를 이미 쓰는 프로세스가 있다 — 끄고 다시 채점한다" >&2
    exit 1
  fi
  app_log=$(mktemp)
  cd "$APP_DIR" || { echo "프로젝트 폴더가 없다: $APP_DIR" >&2; exit 1; }
  setsid python3 -m uvicorn app.main:app --host 127.0.0.1 --port "$port" > "$app_log" 2>&1 &
  app_pid=$!
  trap stop_app EXIT
  for _ in $(seq 1 60); do
    if ! kill -0 "$app_pid" 2> /dev/null; then
      echo "앱이 바로 끝났다:" >&2
      tail -n 20 "$app_log" >&2
      exit 1
    fi
    if curl -sf -m 2 -o /dev/null "$base/health"; then
      return 0
    fi
    sleep 0.5
  done
  echo "30초 안에 $base/health 가 응답하지 않았다. 앱 출력:" >&2
  tail -n 20 "$app_log" >&2
  exit 1
}

stop_app() {
  kill -TERM -- "-$app_pid" 2> /dev/null || kill -TERM "$app_pid" 2> /dev/null
  sleep 0.5
  kill -KILL -- "-$app_pid" 2> /dev/null || true
  rm -f "$app_log"
}

# request <메서드> <경로> [JSON 본문] → 전역 code, body
request() {
  if [ -n "${3:-}" ]; then
    out=$(curl -s -m 10 -w '\n%{http_code}' -X "$1" "$base$2" -H 'content-type: application/json' -d "$3")
  else
    out=$(curl -s -m 10 -w '\n%{http_code}' -X "$1" "$base$2")
  fi
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  echo "$1 $2 → $code $body"
}
