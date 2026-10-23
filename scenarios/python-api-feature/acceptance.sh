#!/bin/bash
# 인수 검사 — 앱을 띄우고 POST /items/{id}/archive 의 요구사항 하나를 요청으로 확인한다.
# 사용: acceptance.sh ok | twice | missing
set -uo pipefail
source "$(dirname "$0")/app-lib.sh"

start_app 3200
case "${1:-}" in
  ok)
    request POST /items '{"name":"pen","price":3}'
    id=$(echo "$body" | jq -r .id)
    request POST "/items/$id/archive"
    [ "$code" = 200 ] || { echo "200 이어야 한다" >&2; exit 1; }
    echo "$body" | jq -e --argjson id "$id" '.id == $id and .name == "pen" and .price == 3 and .archived == true' > /dev/null \
      || { echo "본문이 {id, name, price, archived: true} 여야 한다" >&2; exit 1; }
    ;;
  twice)
    request POST /items '{"name":"pen"}'
    id=$(echo "$body" | jq -r .id)
    request POST "/items/$id/archive"
    request POST "/items/$id/archive"
    [ "$code" = 409 ] || { echo "이미 보관된 항목은 409 여야 한다" >&2; exit 1; }
    ;;
  missing)
    request POST /items/9999/archive
    [ "$code" = 404 ] || { echo "없는 항목은 404 여야 한다" >&2; exit 1; }
    echo "$body" | jq -e '.detail == "not found"' > /dev/null || { echo '본문은 기존 엔드포인트와 같은 {"detail": "not found"} 여야 한다' >&2; exit 1; }
    ;;
  *)
    echo "사용: acceptance.sh ok|twice|missing" >&2
    exit 2
    ;;
esac
echo "통과"
