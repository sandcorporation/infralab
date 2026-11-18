#!/usr/bin/env bash
# 외부 기반 이미지는 `이름:정확한버전@sha256:…` 로만 쓴다.
# 떠다니는 태그(postgres:17-alpine 등)는 상류가 새 이미지를 내면 배포 때 db 같은 상태 있는 컨테이너를 다시 만든다.
# 검사: compose 의 `image:`(변수 `${…}` 로 시작하는 자체 이미지는 제외)와 Dockerfile 의 `FROM`(앞 단계 별칭은 제외).
# 이미지를 올릴 때는 Dependabot PR(.github/dependabot.yml)이 태그와 digest 를 함께 바꾼다.
# 쓰는 법: check_image_pins.sh [파일…]  (인자가 없으면 저장소의 운영 compose·Dockerfile 전부)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
  set -- compose.prod.yml $(git ls-files '*Dockerfile' '*.Dockerfile')
fi

bad=0
for f in "$@"; do
  case "$f" in
    *Dockerfile)
      stages=" "
      while read -r kw img rest; do
        [ "${kw^^}" = FROM ] || continue
        alias=$(sed -nE 's/^[Aa][Ss][[:space:]]+([^[:space:]]+).*/\1/p' <<<"$rest")
        if [[ "$stages" != *" $img "* && "$img" != *'$'* && "$img" != scratch && "$img" != *@sha256:* ]]; then
          echo "$f: FROM $img — digest(@sha256:…) 가 없다" >&2; bad=1
        fi
        [ -n "$alias" ] && stages="$stages$alias "
      done < <(sed -E 's/--platform=[^[:space:]]+[[:space:]]+//' "$f")
      ;;
    *)
      while read -r img; do
        [[ "$img" == '$'* || "$img" == *@sha256:* ]] && continue
        echo "$f: image: $img — digest(@sha256:…) 가 없다" >&2; bad=1
      done < <(sed -nE 's/^[[:space:]]*image:[[:space:]]*["'\'']?([^"'\''[:space:]]+).*/\1/p' "$f")
      ;;
  esac
done
[ "$bad" -eq 0 ] && echo "이미지 고정 검사 통과 ($# 파일)"
exit "$bad"
