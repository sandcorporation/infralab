// 운영 = production 브랜치 머리(#53). 이 잡은 production 만 배포한다(잡 브랜치 지정자 */production).
//
//   main push(또는 공장 병합 뒤 dispatch) → GitHub Actions release.yml: 검사(ci.yml)와 이미지(image.yml)를 나란히
//                                          → 둘 다 초록이면 production fast-forward
//   production push → 여기: 굽지도 검사하지도 않는다. 그 sha 의 ghcr 이미지 넷이 있는지 보고
//                     운영 서버에서 pull → db → DB 확인 → migrate → backend 교체 → web → 헬스 확인(실패하면 자동 롤백)
//
// 파이프라인은 Jenkins 공용 라이브러리 sandcorp(sandcorporation/jenkins-shared)의 sandcorpDeploy 에 있다.
// 여기에는 이 저장소가 넘기는 값만 둔다. 흐름·환경변수 이름·서버 쪽 할 일은 docs/ops/deploy.md. 파라미터:
//   ROLLBACK_SHA      비상 되돌리기: Actions 가 GHCR 에 게시한 sha 이미지로 배포. production 은 그대로 — 정석은 main 에 revert PR.
//
// agent·workstation 은 운영 서버에서 돌지 않는다 — 학생 compose.yml 이 그 sha 주소를 쓰도록 backend 에 넘기려고(compose.prod.yml)
// 함께 받는다. 그 sha 이미지가 ghcr 에 다 오른 뒤에만 학생에게 그 주소가 나간다.
@Library('sandcorp') _

sandcorpDeploy(
  name: 'infralab',
  deployFrom: 'production',
  images: [
    [repo: 'ghcr.io/sandcorporation/infralab-backend', envVar: 'INFRALAB_BACKEND_IMAGE'],
    [repo: 'ghcr.io/sandcorporation/infralab-web', envVar: 'INFRALAB_WEB_IMAGE'],
    [repo: 'ghcr.io/sandcorporation/infralab-agent', envVar: 'INFRALAB_AGENT_IMAGE'],
    [repo: 'ghcr.io/sandcorporation/infralab-workstation', envVar: 'INFRALAB_WORKSTATION_IMAGE'],
  ],
  imageWaitHint: 'https://github.com/sandcorporation/infralab/actions/workflows/release.yml',
  composeProject: 'infralab',
  composeFiles: ['compose.prod.yml'],
  requiredEnv: ['DJANGO_SECRET_KEY', 'POSTGRES_PASSWORD', 'DJANGO_ALLOWED_HOSTS', 'DASHBOARD_ORIGIN'],
  service: 'backend',
  preServices: ['db'],
  dbCheck: 'python manage.py check --database default',
  migrate: ['python manage.py migrate --noinput'],
  extraServices: ['web'],
  healthCmd: '''python -c "import os, urllib.request as u; host = os.environ.get('DJANGO_ALLOWED_HOSTS', 'localhost').split(',')[0].strip(); print(u.urlopen(u.Request('http://127.0.0.1:8000/api/health', headers={'Host': host}), timeout=5).read().decode())"''',
)
