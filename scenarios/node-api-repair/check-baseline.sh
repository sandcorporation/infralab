#!/bin/bash
# 사용: check-baseline.sh <시나리오 id> <경로>...
# record-baseline.sh 가 남긴 기준과 지금 상태를 견준다. 바뀐·사라진·새로 생긴 파일을 출력하고, 하나라도 있으면 비정상 종료한다.
# 출력(어긋난 파일 목록)이 그대로 채점 증거가 된다.
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "사용: check-baseline.sh <시나리오 id> <경로>..." >&2
  exit 2
fi
id=$1
shift
app=${APP_DIR:-/work/app}
dir="$HOME/.infralab/$id/baseline"
bad=0

for path in "$@"; do
  name=$(printf '%s' "$path" | tr '/' '_')
  base="$dir/$name.sha256"
  if [ ! -f "$base" ]; then
    echo "기준 기록이 없다: $path (환경 준비를 다시 한다)" >&2
    bad=1
    continue
  fi
  now=$(cd "$app" 2>/dev/null && { if [ -d "$path" ]; then find "$path" -type f; elif [ -e "$path" ]; then echo "$path"; fi; } | LC_ALL=C sort | xargs -r sha256sum)
  # 파일 이름 → 해시 대응으로 바꿔 세 종류의 차이를 가른다.
  while read -r hash file; do
    [ -z "$file" ] && continue
    cur=$(printf '%s\n' "$now" | awk -v f="$file" '$2 == f { print $1 }')
    if [ -z "$cur" ]; then
      echo "사라짐: $file"
      bad=1
    elif [ "$cur" != "$hash" ]; then
      echo "바뀜: $file"
      bad=1
    fi
  done < "$base"
  while read -r hash file; do
    [ -z "$file" ] && continue
    if ! awk -v f="$file" '$2 == f { found = 1 } END { exit !found }' "$base"; then
      echo "새로 생김: $file"
      bad=1
    fi
  done <<< "$now"
done

if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "기준과 같다: $*"
