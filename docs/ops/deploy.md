# 운영 배포

도메인: `infralab.sandcorp.co.kr`. 운영 버전 = `production` 브랜치 머리.

## 흐름

```
main push(사람 병합)            ─┐
공장 병합 뒤 release.yml dispatch ─┴→ GitHub Actions release.yml
                                     ├ check   ci.yml(workflow_call) — PR 과 같은 검사
                                     ├ image   image.yml(workflow_call) — ghcr <이미지>:<sha>
                                     └ promote 둘 다 초록이면 production fast-forward(scripts/promote.sh)
production push → Jenkins(Jenkinsfile → jenkins-shared sandcorpDeploy)
                  이미지 다섯 확인 → 문제은행 받기(선택) → pull → db → manage.py check → migrate → backend 교체 → proxy·web → /api/health
                  실패하면 직전 성공 sha 로 자동 롤백
```

| 이미지 | 플랫폼 | 어디서 |
| --- | --- | --- |
| `ghcr.io/sandcorporation/infralab-backend:<sha>` | linux/arm64 | 운영 서버 — Django + gunicorn(`docker/backend.prod.Dockerfile`) |
| `ghcr.io/sandcorporation/infralab-web:<sha>` | linux/arm64 | 운영 서버 — nginx: Vite 빌드 정적 파일, `/api` → backend, `/exam-proxy/` → proxy(`docker/web.Dockerfile`, `web/nginx.conf`) |
| `ghcr.io/sandcorporation/infralab-proxy:<sha>` | linux/arm64 | 운영 서버 — 시험 AI 프록시(`proxy/Dockerfile`) |
| `ghcr.io/sandcorporation/infralab-agent:<sha>` | linux/amd64, arm64 | 응시자 PC — 학생 `compose.yml` |
| `ghcr.io/sandcorporation/infralab-workstation:<sha>` | linux/amd64, arm64 | 응시자 PC — 학생 `compose.yml` |

- 두 아키텍처 이미지는 아키텍처마다 `<sha>-amd64`·`<sha>-arm64` 를 올리고 `<sha>` 로 묶는다. 빌드 캐시는 `:buildcache[-<arch>]`.
- 학생 `compose.yml` 의 이미지 주소: Jenkins 가 `INFRALAB_AGENT_IMAGE`·`INFRALAB_WORKSTATION_IMAGE` 에 배포 sha 의 주소를 넣고, `compose.prod.yml` 이 backend 의 `AGENT_IMAGE`·`WORKSTATION_IMAGE` 로 넘긴다. 비면 backend 기본값(로컬 이름 `infralab/agent:dev` 등).
- 외부 기반 이미지(`compose.prod.yml` 의 db, 각 Dockerfile 의 `FROM`)는 `이름:정확한버전@sha256:…` 로 고정한다. 떠다니는 태그는 상류가 새 이미지를 내면 배포 때 db 를 다시 만든다. 올릴 때는 Dependabot PR(`.github/dependabot.yml`)로 바꾸고, CI(`scripts/check_image_pins.sh`)가 digest 없는 이미지를 막는다. db digest 가 바뀌는 배포는 db 컨테이너를 한 번 다시 만든다(볼륨은 그대로).
- 되돌리기: main 에 revert PR(같은 흐름). 급하면 Jenkins 파라미터 `ROLLBACK_SHA`(production 은 그대로).

## 운영 환경변수(서버의 `.env`)

| 이름 | 필수 | 뜻 |
| --- | --- | --- |
| `DJANGO_SECRET_KEY` | 예 | Django 서명 키. 개발 기본값이면 부팅이 막힌다 |
| `POSTGRES_PASSWORD` | 예 | db 컨테이너와 backend 가 같이 쓴다 |
| `DJANGO_ALLOWED_HOSTS` | 예 | 콤마 구분. 첫 값이 헬스 확인의 Host 헤더다 — 도메인을 맨 앞에. compose 안 이름 `backend`(proxy 가 부르는 Host)는 compose 가 `DJANGO_INTERNAL_HOSTS` 로 따로 늘 허용한다 |
| `DASHBOARD_ORIGIN` | 예 | 대시보드 오리진(`https://infralab.sandcorp.co.kr`). 학생 에이전트가 이 오리진의 요청만 받는다. 첫 값이 로그인 `redirect_uri`(`…/api/auth/callback`)·토큰 `aud`(`…/api`)의 원점이고, 쿠키로 상태를 바꾸는 요청의 `Origin` 도 이 값들만 받는다 |
| `INFRALAB_AUTH_CLIENT_ID`, `INFRALAB_AUTH_CLIENT_SECRET` | 예 | sandcorp-auth 기밀 클라이언트. 비면 로그인만 503(기동·`/api/health` 는 된다) |
| `INFRALAB_AUTH_WEBHOOK_SECRET` | 예 | auth 웹훅(탈퇴 `user.deleted`·계정 합치기 `user.merged`) 서명 비밀. 비면 웹훅이 503 |
| `INFRALAB_AUTH_URL` | 아니오 | 기본 `https://auth.sandcorp.co.kr` |
| `INFRALAB_AUTH_OWNER_SUB` | 아니오 | 대표 토큰(`acct` 없음)의 `sub`, 기본 `farrar142`. 다르면 그 토큰의 로그인을 거부한다 |
| `INFRALAB_AUTH_SCOPE` | 아니오 | 요청 스코프, 기본 `openid profile infralab`. 일반 사용자에게 `openid`·`profile` 이 막혀 있으면 `infralab` — ID 토큰 없이 `sub` 로만 로그인한다(표시 이름 없음) |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | 아니오 | 전체 오리진, 콤마 구분 |
| `POSTGRES_DB`, `POSTGRES_USER` | 아니오 | 기본 `infralab` |
| `FLOCI_IMAGE` | 아니오 | 학생 compose 의 Floci 이미지. 비면 backend 기본값 |
| `GUNICORN_WORKERS` | 아니오 | 기본 2 |
| `INFRALAB_ANTHROPIC_EXAM_KEY`, `INFRALAB_OPENAI_EXAM_KEY` | 시험 | 시험용 공급사 키. **`proxy` 서비스만** 받는다(backend 는 받지 않는다) |
| `INFRALAB_EXAM_PROXY_SECRET` | 시험 | proxy 와 backend 가 나누는 공유 비밀. 둘 다 같은 값을 받는다 |
| `INFRALAB_EXAM_PROXY_URL` | 시험 | backend 가 지원자에게 알려 줄 프록시 주소. 운영은 `https://infralab.sandcorp.co.kr/exam-proxy`(web 의 `/exam-proxy/` 가 proxy 로 넘긴다). backend 가 `/anthropic`·`/openai/v1` 을 붙인다. 기본 `http://proxy:58090` 은 지원자 PC 가 닿지 못한다 |
| `INFRALAB_GRADER_ANTHROPIC_KEY` | 시험 | 루브릭 채점 키(backend 만). 비면 가짜 채점기 |
| `INFRALAB_PROBLEMS_DIR` | 아니오 | backend 안의 문제은행 경로. 기본 `/problems` — 호스트 폴더(`INFRALAB_PROBLEMS_HOST_DIR`, 기본 `./problems`)를 읽기 전용으로 붙인다. 폴더가 없거나 비면 「숨은 검사」 건너뜀 경고만 남고 기동한다 |
| `INFRALAB_PROXY_TRUST_FORWARDED` | 아니오 | 기본 `1` — proxy 는 web(nginx)만 부르고, nginx 가 `X-Forwarded-For` 를 지원자 주소 하나로 덮어 넘긴다 |
| `INFRALAB_PROXY_TOKEN_PER_MINUTE`, `INFRALAB_PROXY_TOKEN_BURST` | 아니오 | 임시 토큰별 요청 한도(분당 120, 한꺼번에 60). 넘으면 429. `0` 이면 끔 |
| `HTTP_BIND`, `HTTP_PORT` | 아니오 | web 이 듣는 호스트 주소·포트. 기본 `127.0.0.1:18093` |

Jenkins 가 넣는 값(`.env` 에 쓰지 않는다): `INFRALAB_BACKEND_IMAGE`, `INFRALAB_WEB_IMAGE`, `INFRALAB_PROXY_IMAGE`, `INFRALAB_AGENT_IMAGE`, `INFRALAB_WORKSTATION_IMAGE`.

빌드 때 값은 없다. 운영 화면은 「Sandcorp 계정으로 로그인」 버튼 하나이고, 개발용 로그인(`/api/auth/dev-login`)은 `DJANGO_DEBUG=false` 에서 404 다.

## 서버 쪽에서 할 일

- [ ] Jenkins 잡: multibranch 또는 파이프라인, 저장소 `sandcorporation/infralab`, 브랜치 지정자 `*/production`, `Jenkinsfile`, GitHub push 웹훅.
- [ ] 운영 서버의 Jenkins 작업 디렉터리에 `.env`(위 필수 네 개 + 필요한 선택 값). 저장소에 넣지 않는다. **함정**: Jenkins 첫 클론이 작업 디렉터리를 비우므로 `.env` 는 첫 빌드(클론) 뒤에 넣고 다시 빌드한다(먼저 넣으면 지워진다).
- [ ] 리버스 프록시 호스트 `infralab.sandcorp.co.kr` → web 컨테이너(`HTTP_BIND:HTTP_PORT`). TLS 는 프록시에서 끝내고 `X-Forwarded-Proto` 를 넘긴다.
- [ ] DB 볼륨(`infralab_db`) 백업 — 정기 `pg_dump` 또는 볼륨 스냅숏.
- [ ] sandcorp-auth 에 기밀 클라이언트 등록(auth 조율자): redirect_uri `https://infralab.sandcorp.co.kr/api/auth/callback`, 리소스 `https://infralab.sandcorp.co.kr/api` 와 그 스코프 `infralab`(일반 사용자 허용), 클라이언트의 「일반 사용자 허용」, 웹훅 URL `https://infralab.sandcorp.co.kr/api/auth/webhook`. 나온 client id·secret·웹훅 비밀을 `.env` 에.
- [ ] GitHub ruleset: `production` 브랜치 강제 push·삭제 금지(승격은 fast-forward 만).
- [ ] ghcr 패키지 다섯(`infralab-backend`·`-web`·`-proxy`·`-agent`·`-workstation`)의 공개 범위 — 응시자 PC 가 로그인 없이 pull 하려면 agent·workstation 은 공개.
- [x] 시험 모드 Jenkins 배선(#82): proxy 이미지(`images`·`extraServices`), 문제은행 받기(`extraCheckouts` optional, 자격 `infralab-problems-deploy-key`, `problems.ref`), 공개 주소 `/exam-proxy/`(web nginx).
- [ ] 시험 모드 서버 몫: `.env` 에 공급사 키 둘·채점 키, `INFRALAB_EXAM_PROXY_URL=https://infralab.sandcorp.co.kr/exam-proxy`. Jenkins 자격 `infralab-problems-deploy-key`(문제은행 저장소의 읽기 전용 deploy key) 등록과 `problems.ref` 에 고정 sha — 그 전에는 배포 로그에 「경고: 다른 저장소 받기 건너뜀(optional)」이 남고 숨은 검사만 건너뛴다.
- [ ] 첫 강사 지정: `docker compose -f compose.prod.yml run --rm backend python manage.py set_instructor sandcorp:<sub>` — 「기본 조직」 owner 로 넣는다. Sandcorp 계정으로 한 번 로그인한 뒤에 한다(그 전에는 사용자가 없다). `sub` 는 `/api/accounts/me` 의 `username` 에서 본다.

## 시험 모드(AI 프록시·문제은행)

- `compose.prod.yml` 의 `proxy` 서비스를 Jenkins 가 backend 다음에 web 과 함께 띄운다(`extraServices`). 공개 포트는 없고, 지원자 PC 는 `https://infralab.sandcorp.co.kr/exam-proxy` 로 부른다 — web(nginx)이 접두어를 떼고 proxy 로 넘긴다(스트리밍 버퍼링 끔, 600초). 한도: nginx 가 본문 32 MiB·IP(`X-Forwarded-For` 끝 주소)별 20r/s(burst 200), proxy 가 임시 토큰별 분당 120(burst 60). 토큰이 없거나 틀리면 401(공급사 꼴 오류). 경로 시험은 `bash scripts/check_exam_proxy_route.sh`(CI `exam-proxy-route`).
- `INFRALAB_EXAM_PROXY_SECRET` 이 비면 proxy 가 기동하지 않는다(재시작 반복) — 다른 서비스와 배포는 그대로다.
- 문제은행은 비공개 저장소다. Jenkins 자격 이름은 `infralab-problems-deploy-key`(읽기 전용 deploy key), 받을 커밋은 저장소 루트 `problems.ref` 에 적는다(0 들이면 받지 않는다). Jenkins 가 워크스페이스 `problems/` 에 받는다(선택 — 자격이 없거나 받기에 실패해도 경고만). 받은 폴더가 호스트 `INFRALAB_PROBLEMS_HOST_DIR`(기본 `./problems`)이고 backend 에 `INFRALAB_PROBLEMS_DIR` 로 붙는다. 공개 이미지에는 굽지 않는다.
- 공급사 키·공유 비밀은 서버 `.env` 에만 둔다. 공급사 키는 proxy 만 받는다.

## 로컬에서 운영 compose 확인

```
DJANGO_SECRET_KEY=local-check POSTGRES_PASSWORD=local-check \
  docker compose -p infralab-prodcheck -f compose.prod.yml up -d --build --wait
curl -s http://127.0.0.1:18093/api/health      # {"status":"ok"} — DB 를 못 쓰면 503 {"status":"error","failed":["db"]}
curl -s 'http://127.0.0.1:18093/api/health?scope=ready'   # db 만 본다
docker compose -p infralab-prodcheck -f compose.prod.yml down -v
```

이미지 주소를 주지 않으면 로컬에서 빌드한다(amd64 머신이면 amd64).

## health 범위

- `/api/health` — db + (`INFRALAB_EXAM_PROXY_SECRET` 이 설정된 때만) AI 프록시 `GET /healthz`(1초 제한, `INFRALAB_EXAM_PROXY_URL` 기본 `http://proxy:58090`). 실패하면 503 `{"status":"error","failed":["proxy"]}`(이름만). Gatus 외부 감시가 쓴다.
- `/api/health?scope=ready` — db 만. compose backend healthcheck 와 Jenkins healthCmd 가 쓴다. 프록시가 죽어도 backend 가 unhealthy·롤백으로 빠지지 않는다.
