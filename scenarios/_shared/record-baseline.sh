#!/bin/bash
# 사용: record-baseline.sh <시나리오 id> <경로>...
# 프로젝트(/work/app, APP_DIR 로 바꿀 수 있다) 기준 경로들의 파일 해시 목록을 홈 볼륨의
# ~/.infralab/<시나리오 id>/baseline/ 에 남긴다. 디렉터리는 안의 모든 파일을 본다. setup 이 부른다.
# 기준은 /work 가 아니라 홈 볼륨에 둔다 — 학생이 지우거나 바꿀 수 없는 자리다.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "사용: record-baseline.sh <시나리오 id> <경로>..." >&2
  exit 2
fi
id=$1
shift
app=${APP_DIR:-/work/app}
dir="$HOME/.infralab/$id/baseline"
rm -rf "$dir"
mkdir -p "$dir"

for path in "$@"; do
  full="$app/$path"
  if [ ! -e "$full" ]; then
    echo "기준으로 삼을 경로가 없다: $path" >&2
    exit 1
  fi
  name=$(printf '%s' "$path" | tr '/' '_')
  (cd "$app" && if [ -d "$path" ]; then find "$path" -type f -not -path '*/__pycache__/*' -not -path '*/.pytest_cache/*'; else echo "$path"; fi | LC_ALL=C sort | xargs -r sha256sum) > "$dir/$name.sha256"
  echo "기준 기록: $path ($(wc -l < "$dir/$name.sha256") 파일)"
done
