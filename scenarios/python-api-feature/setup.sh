#!/bin/bash
# 환경 준비 — infralab-labs 의 labs/python-api 를 태그로 받아 /work/app 에 깨끗한 git 이력으로 놓고 의존성을 설치한다.
set -euo pipefail

TAG=v3
REPO=https://github.com/sandcorporation/infralab-labs
FOLDER=labs/python-api

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
printf '__pycache__/\n.pytest_cache/\n' > .gitignore
git init -q
git add -A
git -c user.name=infralab -c user.email=infralab@example.com commit -q -m "초기 상태"

echo "== pip install -r requirements.txt"
if ! pip install -q -r requirements.txt; then
  echo "의존성 설치에 실패했다 — workstation 의 인터넷(PyPI) 연결을 확인한다" >&2
  exit 1
fi

record-baseline.sh python-api-feature tests requirements.txt
echo "/work/app 준비 완료 ($TAG)"
