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
