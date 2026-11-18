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
| `DASHBOARD_ORIGIN` | 예 | 대시보드 오리진(`https://infralab.sandcorp.co.kr`). 학생 에이전트가 이 오리진의 요청만 받는다 |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | 아니오 | 전체 오리진, 콤마 구분 |
| `JWT_SIGNING_KEY` | 아니오 | 비우면 `DJANGO_SECRET_KEY` |
| `POSTGRES_DB`, `POSTGRES_USER` | 아니오 | 기본 `infralab` |
| `ACCESS_TOKEN_TTL_MINUTES`, `REFRESH_TOKEN_TTL_DAYS` | 아니오 | 기본 30분·14일 |
| `FLOCI_IMAGE` | 아니오 | 학생 compose 의 Floci 이미지. 비면 backend 기본값 |
| `GUNICORN_WORKERS` | 아니오 | 기본 2 |
| `HTTP_BIND`, `HTTP_PORT` | 아니오 | web 이 듣는 호스트 주소·포트. 기본 `127.0.0.1:18093` |

Jenkins 가 넣는 값(`.env` 에 쓰지 않는다): `INFRALAB_BACKEND_IMAGE`, `INFRALAB_WEB_IMAGE`, `INFRALAB_AGENT_IMAGE`, `INFRALAB_WORKSTATION_IMAGE`.

빌드 때 값(GitHub 저장소 변수, 비밀 아님): `VITE_KAKAO_REST_KEY` — 카카오 REST API 키. 비면 화면은 개발용 로그인만 보이고, 운영 backend 는 fake 로그인을 거절한다.

## 서버 쪽에서 할 일

- [ ] Jenkins 잡: multibranch 또는 파이프라인, 저장소 `sandcorporation/infralab`, 브랜치 지정자 `*/production`, `Jenkinsfile`, GitHub push 웹훅.
- [ ] 운영 서버의 Jenkins 작업 디렉터리에 `.env`(위 필수 네 개 + 필요한 선택 값). 저장소에 넣지 않는다.
- [ ] 리버스 프록시 호스트 `infralab.sandcorp.co.kr` → web 컨테이너(`HTTP_BIND:HTTP_PORT`). TLS 는 프록시에서 끝내고 `X-Forwarded-Proto` 를 넘긴다.
- [ ] DB 볼륨(`infralab_db`) 백업 — 정기 `pg_dump` 또는 볼륨 스냅숏.
- [ ] GitHub 저장소 변수 `VITE_KAKAO_REST_KEY`, 카카오 개발자 콘솔 Redirect URI `https://infralab.sandcorp.co.kr/auth/kakao/callback`.
- [ ] GitHub ruleset: `production` 브랜치 강제 push·삭제 금지(승격은 fast-forward 만).
- [ ] ghcr 패키지 넷(`infralab-backend`·`-web`·`-agent`·`-workstation`)의 공개 범위 — 응시자 PC 가 로그인 없이 pull 하려면 agent·workstation 은 공개.
- [ ] 첫 강사 지정: `docker compose -f compose.prod.yml run --rm backend python manage.py set_instructor …`.

## 로컬에서 운영 compose 확인

```
DJANGO_SECRET_KEY=local-check POSTGRES_PASSWORD=local-check \
  docker compose -p infralab-prodcheck -f compose.prod.yml up -d --build --wait
curl -s http://127.0.0.1:18093/api/health      # {"status": "ok", "db": "ok"}
docker compose -p infralab-prodcheck -f compose.prod.yml down -v
```

이미지 주소를 주지 않으면 로컬에서 빌드한다(amd64 머신이면 amd64).
