# 고장·제약 시나리오 메모 (2026-10-23)

## k8s-web-down

- 「Deployment 를 지우고 다시 만들지 않음」은 **UID 비교**로 판정한다. setup 이 Deployment `web` 의 `metadata.uid` 를 홈 볼륨(`~/.infralab/k8s-web-down/web.uid`)에 남기고 `check-web-kept.sh` 가 지금 UID 와 견준다. 라벨은 매니페스트를 복사해 다시 만들면 따라오고 `creationTimestamp` 는 준비 시각과의 비교가 시계에 기대지만, UID 는 새로 만들면 반드시 바뀌고 학생이 옮길 수 없다.
- 실측: 환경 준비 직후 채점 2/4(제약 둘 통과, 엔드포인트·ready 레플리카 실패) → Service 셀렉터·레플리카 고친 뒤 4/4 → Deployment 를 지우고 `kubectl create deployment web --image=nginx --replicas=2` 로 다시 만들면 제약 검사가 실패하고 힌트가 보인다.
- 검사 출력에 쓰는 정규식은 끝이 `$` 라서 줄바꿈 때문에 맞지 않을 수 있다(RE2 는 `(?m)` 없이는 텍스트 끝에서만 `$`). 숫자 검사는 `^\s*…\s*$` 로 쓴다.

## ec2-unreachable

- Floci 가 보안 그룹을 강제하지 않아 「닿는다」 검사는 보안 그룹 인바운드 + 8080 응답의 합이다(`reach-check.sh`, 근거는 floci-findings). 환경 준비의 setup 은 nginx 가 응답할 때까지(약 40초, 상한 200초) 기다리고 끝난다.
- 실측: 환경 준비 직후 채점 2/3(「닿는다」만 실패, 제약 둘 통과) → `authorize-security-group-ingress` 로 8080 을 열면 3/3 → 22 포트를 더 열고 인스턴스를 하나 더 띄우면 제약 둘이 모두 실패하고 어긋난 규칙이 출력에 보인다.

## node-api-repair (공유 검사 스크립트)

- 프로젝트는 infralab-labs 태그 v2 의 labs/node-api. setup 이 shallow clone → /work/app 복사 → git init + 첫 커밋 → npm ci → record-baseline.sh 순서로 약 27초(인터넷 필요, 상한 240초).
- 공유 스크립트 원본은 scenarios/_shared/ (record-baseline.sh · check-baseline.sh · serve-and-curl.sh), 시나리오 디렉터리마다 복사본을 두고 test_shared_scripts.py 가 원본과 같은지 지킨다. 기준은 홈 볼륨의 ~/.infralab/<id>/baseline/ 에 남고 파일 경로 → 해시 목록이다. 디렉터리에 새로 생긴 파일도 위반으로 센다.
- 실측: 환경 준비 직후 채점 3/4(npm test 만 실패, 제약 통과) → sum·date 두 버그를 고치면 4/4 → tests/ 수정·새 테스트 추가·package-lock.json 수정은 제약 실패이고 바뀜/새로 생김 목록이 출력에 보인다 → 환경 준비를 다시 하면 /work/app 이 처음 상태(버그 있음)로 돌아간다.

## python-api-feature

- 프로젝트는 infralab-labs 의 labs/python-api. pip 설치는 PIP_USER=1 로 홈 볼륨(/root/.local)에 가고 PATH 에 /root/.local/bin 이 있어 pytest·uvicorn 이 바로 되며 컨테이너를 다시 만들어도 남는다(이미지에 추가). 환경 준비 약 16초.
- 인수 검사는 acceptance.sh 가 앱(uvicorn, 포트 3200)을 띄워 요청하고, 공개 API 유지는 api-shape.sh 가 보관하지 않은 항목의 키가 id·name·price 뿐인지 본다. 둘 다 app-lib.sh 를 쓴다. 기준 해시는 __pycache__·.pytest_cache 를 제외한다(공유 스크립트).
- 「없는 항목은 404」가 구현 전에도 통과하지 않게(없는 라우트도 404) 본문 {"detail": "not found"} 까지 요구한다.
- 실측: 환경 준비 직후 채점 5/7(인수 두 건 실패, 나머지 통과) → 구현 뒤 7/7 → 모든 항목에 archived 키를 넣고 requirements.txt 를 바꾸면 4/7, 두 제약이 실패하고 어긋난 응답·바뀐 파일이 출력에 보인다.

## java-api-repair

- 프로젝트는 infralab-labs v3 의 labs/java-api(Javalin, Gradle 9.1 wrapper, toolchain 25). 환경 준비의 `./gradlew test` 가 Gradle 배포본과 의존성을 ~/.gradle(홈 볼륨)에 받는다. 소요: 처음 약 33초(배포본·의존성 다운로드), 이후 5~10초. setup_timeout 은 300초로 여유를 뒀다.
- 호스트 폴더를 마운트한 /work 에서는 Gradle 의 파일 변경 감시(VFS watch)가 편집을 놓쳐 소스를 고쳐도 compileJava 가 UP-TO-DATE 로 남았다 → 환경 준비가 홈의 ~/.gradle/gradle.properties 에 org.gradle.vfs.watch=false 를 쓴다(프로젝트 파일은 건드리지 않는다).
- labs v2 의 java-api 는 jackson-databind 가 없어 `/health` 가 500 이었다 → v3 에서 의존성이 들어와 서비스 검사는 `/health` 본문(`{"status":"ok"}`)을 본다(SERVE_ANY_STATUS 우회는 없앴다). 시나리오 셋은 모두 v3 를 쓴다.
- 실측: 환경 준비 직후 채점 3/4(테스트 실패, 나머지 통과) → off-by-one 수정 뒤 4/4 → build.gradle.kts 를 바꾸면 2/4(제약 실패, 「바뀜: build.gradle.kts」 출력).
