#!/bin/bash
# 기존 공개 API 의 응답 모양이 그대로인지 앱을 띄워 확인한다 — 보관하지 않은 항목은 {id, name, price} 뿐이다.
set -uo pipefail
source "$(dirname "$0")/app-lib.sh"

start_app 3201
fail=0
fails() { echo "어긋남: $1" >&2; fail=1; }

request POST /items '{"name":"pen","price":3}'
[ "$code" = 201 ] || fails "POST /items 는 201"
echo "$body" | jq -e 'keys == ["id","name","price"]' > /dev/null || fails "POST /items 본문의 키는 id, name, price"
id=$(echo "$body" | jq -r .id)

request GET /items
[ "$code" = 200 ] || fails "GET /items 는 200"
echo "$body" | jq -e 'type == "array" and (.[0] | keys == ["id","name","price"])' > /dev/null || fails "GET /items 항목의 키는 id, name, price"

request GET "/items/$id"
[ "$code" = 200 ] || fails "GET /items/{id} 는 200"
echo "$body" | jq -e 'keys == ["id","name","price"]' > /dev/null || fails "GET /items/{id} 본문의 키는 id, name, price"

request PUT "/items/$id" '{"name":"pencil","price":5}'
[ "$code" = 200 ] || fails "PUT /items/{id} 는 200"
echo "$body" | jq -e '. == {"id": '"$id"', "name": "pencil", "price": 5}' > /dev/null || fails "PUT /items/{id} 본문"

request GET /items/9999
[ "$code" = 404 ] || fails "없는 항목 조회는 404"

request DELETE "/items/$id"
[ "$code" = 204 ] || fails "DELETE /items/{id} 는 204"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "기존 응답 모양 유지"
