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
                  이미지 넷 확인 → pull → db → manage.py check → migrate → backend 교체 → web → /api/health
                  실패하면 직전 성공 sha 로 자동 롤백
```

| 이미지 | 플랫폼 | 어디서 |
| --- | --- | --- |
| `ghcr.io/sandcorporation/infralab-backend:<sha>` | linux/arm64 | 운영 서버 — Django + gunicorn(`docker/backend.prod.Dockerfile`) |
| `ghcr.io/sandcorporation/infralab-web:<sha>` | linux/arm64 | 운영 서버 — nginx: Vite 빌드 정적 파일, `/api` → backend(`docker/web.Dockerfile`, `web/nginx.conf`) |
| `ghcr.io/sandcorporation/infralab-agent:<sha>` | linux/amd64, arm64 | 응시자 PC — 학생 `compose.yml` |
| `ghcr.io/sandcorporation/infralab-workstation:<sha>` | linux/amd64, arm64 | 응시자 PC — 학생 `compose.yml` |

- 두 아키텍처 이미지는 아키텍처마다 `<sha>-amd64`·`<sha>-arm64` 를 올리고 `<sha>` 로 묶는다. 빌드 캐시는 `:buildcache[-<arch>]`.
- 학생 `compose.yml` 의 이미지 주소: Jenkins 가 `INFRALAB_AGENT_IMAGE`·`INFRALAB_WORKSTATION_IMAGE` 에 배포 sha 의 주소를 넣고, `compose.prod.yml` 이 backend 의 `AGENT_IMAGE`·`WORKSTATION_IMAGE` 로 넘긴다. 비면 backend 기본값(로컬 이름 `infralab/agent:dev` 등).
- 되돌리기: main 에 revert PR(같은 흐름). 급하면 Jenkins 파라미터 `ROLLBACK_SHA`(production 은 그대로).

## 운영 환경변수(서버의 `.env`)

| 이름 | 필수 | 뜻 |
| --- | --- | --- |
| `DJANGO_SECRET_KEY` | 예 | Django 서명 키. 개발 기본값이면 부팅이 막힌다 |
| `POSTGRES_PASSWORD` | 예 | db 컨테이너와 backend 가 같이 쓴다 |
| `DJANGO_ALLOWED_HOSTS` | 예 | 콤마 구분. 첫 값이 헬스 확인의 Host 헤더다 — 도메인을 맨 앞에 |
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
| `HTTP_BIND`, `HTTP_PORT` | 아니오 | web 이 듣는 호스트 주소·포트. 기본 `127.0.0.1:18093` |

Jenkins 가 넣는 값(`.env` 에 쓰지 않는다): `INFRALAB_BACKEND_IMAGE`, `INFRALAB_WEB_IMAGE`, `INFRALAB_AGENT_IMAGE`, `INFRALAB_WORKSTATION_IMAGE`.

빌드 때 값은 없다. 운영 화면은 「Sandcorp 계정으로 로그인」 버튼 하나이고, 개발용 로그인(`/api/auth/dev-login`)은 `DJANGO_DEBUG=false` 에서 404 다.

## 서버 쪽에서 할 일

- [ ] Jenkins 잡: multibranch 또는 파이프라인, 저장소 `sandcorporation/infralab`, 브랜치 지정자 `*/production`, `Jenkinsfile`, GitHub push 웹훅.
- [ ] 운영 서버의 Jenkins 작업 디렉터리에 `.env`(위 필수 네 개 + 필요한 선택 값). 저장소에 넣지 않는다. **함정**: Jenkins 첫 클론이 작업 디렉터리를 비우므로 `.env` 는 첫 빌드(클론) 뒤에 넣고 다시 빌드한다(먼저 넣으면 지워진다).
- [ ] 리버스 프록시 호스트 `infralab.sandcorp.co.kr` → web 컨테이너(`HTTP_BIND:HTTP_PORT`). TLS 는 프록시에서 끝내고 `X-Forwarded-Proto` 를 넘긴다.
- [ ] DB 볼륨(`infralab_db`) 백업 — 정기 `pg_dump` 또는 볼륨 스냅숏.
- [ ] sandcorp-auth 에 기밀 클라이언트 등록(auth 조율자): redirect_uri `https://infralab.sandcorp.co.kr/api/auth/callback`, 리소스 `https://infralab.sandcorp.co.kr/api` 와 그 스코프 `infralab`(일반 사용자 허용), 클라이언트의 「일반 사용자 허용」, 웹훅 URL `https://infralab.sandcorp.co.kr/api/auth/webhook`. 나온 client id·secret·웹훅 비밀을 `.env` 에.
- [ ] GitHub ruleset: `production` 브랜치 강제 push·삭제 금지(승격은 fast-forward 만).
- [ ] ghcr 패키지 넷(`infralab-backend`·`-web`·`-agent`·`-workstation`)의 공개 범위 — 응시자 PC 가 로그인 없이 pull 하려면 agent·workstation 은 공개.
- [ ] 첫 강사 지정: `docker compose -f compose.prod.yml run --rm backend python manage.py set_instructor sandcorp:<sub>` — 「기본 조직」 owner 로 넣는다. Sandcorp 계정으로 한 번 로그인한 뒤에 한다(그 전에는 사용자가 없다). `sub` 는 `/api/accounts/me` 의 `username` 에서 본다.

## 로컬에서 운영 compose 확인

```
DJANGO_SECRET_KEY=local-check POSTGRES_PASSWORD=local-check \
  docker compose -p infralab-prodcheck -f compose.prod.yml up -d --build --wait
curl -s http://127.0.0.1:18093/api/health      # {"status": "ok", "db": "ok"}
docker compose -p infralab-prodcheck -f compose.prod.yml down -v
```

이미지 주소를 주지 않으면 로컬에서 빌드한다(amd64 머신이면 amd64).
