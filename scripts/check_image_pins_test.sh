#!/usr/bin/env bash
# check_image_pins.sh 시험: 떠다니는 태그는 실패, digest 고정·자체 이미지 변수·앞 단계 별칭은 통과.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
D=sha256:0000000000000000000000000000000000000000000000000000000000000000

printf 'services:\n  db:\n    image: postgres:17-alpine\n' > "$t/float.yml"
printf 'services:\n  db:\n    image: postgres:17.11-alpine@%s\n  app:\n    image: ${APP_IMAGE:-app:local}\n' "$D" > "$t/pinned.yml"
printf 'FROM golang:1.23-alpine AS build\nFROM alpine:3.21@%s\n' "$D" > "$t/float.Dockerfile"
printf 'FROM --platform=$BUILDPLATFORM golang:1.23.12-alpine@%s AS build\nFROM build AS test\nFROM alpine:3.21.10@%s\nCOPY --from=build /x /x\n' "$D" "$D" > "$t/pinned.Dockerfile"

fail=0
expect() { # expect <0|1> <파일>
  if bash "$here/check_image_pins.sh" "$2" >/dev/null 2>&1; then got=0; else got=1; fi
  if [ "$got" = "$1" ]; then echo "ok   $(basename "$2")"; else echo "FAIL $(basename "$2"): 기대 $1, 실제 $got"; fail=1; fi
}
expect 1 "$t/float.yml"
expect 0 "$t/pinned.yml"
expect 1 "$t/float.Dockerfile"
expect 0 "$t/pinned.Dockerfile"
bash "$here/check_image_pins.sh" || fail=1
exit "$fail"
