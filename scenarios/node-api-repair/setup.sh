#!/bin/bash
# 고장 내기 — infralab-labs 의 labs/node-api 를 태그로 받아 /work/app 에 깨끗한 git 이력으로 놓는다.
set -euo pipefail

TAG=v3
REPO=https://github.com/sandcorporation/infralab-labs
FOLDER=labs/node-api

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! git clone -q --depth 1 --branch "$TAG" "$REPO" "$tmp/repo"; then
  echo "infralab-labs 를 받지 못했다 — workstation 의 인터넷 연결을 확인한다 ($REPO @ $TAG)" >&2
  exit 1
fi

rm -rf /work/app
mkdir -p /work
cp -r "$tmp/repo/$FOLDER" /work/app

cd /work/app
printf 'node_modules\n' > .gitignore
git init -q
git add -A
git -c user.name=infralab -c user.email=infralab@example.com commit -q -m "초기 상태"

echo "== npm ci"
if ! npm ci --no-audit --no-fund; then
  echo "의존성 설치에 실패했다 — workstation 의 인터넷(npm 레지스트리) 연결을 확인한다" >&2
  exit 1
fi

record-baseline.sh node-api-repair tests package-lock.json
echo "/work/app 준비 완료 ($TAG)"
