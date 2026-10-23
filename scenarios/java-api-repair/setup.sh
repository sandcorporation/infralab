#!/bin/bash
# 환경 준비 — infralab-labs 의 labs/java-api 를 태그로 받아 /work/app 에 깨끗한 git 이력으로 놓고,
# ./gradlew test 를 한 번 돌려 Gradle 배포본과 의존성을 홈 볼륨(~/.gradle)에 받아 둔다. 채점은 --offline 으로 돈다.
set -euo pipefail

TAG=v3
REPO=https://github.com/sandcorporation/infralab-labs
FOLDER=labs/java-api

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
chmod +x gradlew
printf '.gradle/\nbuild/\n' > .gitignore
git init -q
git add -A
git -c user.name=infralab -c user.email=infralab@example.com commit -q -m "초기 상태"

# 호스트 폴더를 마운트한 /work 에서는 파일 변경 감시(VFS watch)가 편집을 놓쳐 컴파일이 UP-TO-DATE 로 남는다 —
# 프로젝트가 아니라 홈의 Gradle 설정에서 끈다. 이미 떠 있는 데몬은 옛 상태를 쥐고 있으니 먼저 내린다.
mkdir -p ~/.gradle
grep -q '^org.gradle.vfs.watch=' ~/.gradle/gradle.properties 2>/dev/null || echo 'org.gradle.vfs.watch=false' >> ~/.gradle/gradle.properties
./gradlew --stop > /dev/null 2>&1 || true

# 시험이 하나 실패하는 것이 정상이다 — 목적은 배포본·의존성을 받아 두는 것이다.
echo "== ./gradlew test (Gradle 배포본과 의존성을 받는다)"
./gradlew test --console=plain > /tmp/gradle-setup.log 2>&1 || true
tail -n 15 /tmp/gradle-setup.log
if ! ls build/test-results/test/*.xml > /dev/null 2>&1; then
  echo "Gradle 이 시험까지 가지 못했다 — workstation 의 인터넷(services.gradle.org, Maven Central) 연결을 확인한다" >&2
  exit 1
fi

record-baseline.sh java-api-repair src/test build.gradle.kts settings.gradle.kts gradle
echo "/work/app 준비 완료 ($TAG)"
