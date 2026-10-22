# infra-agent PoC — 로컬 에이전트 방식 실현 가능성 검증 (2026-10-22)

인프라 수업용 「브라우저 + 학생 로컬 Docker」 구조가 실제로 도는지 이 머신(Windows 11, Docker Desktop 29.6.2,
WSL2 메모리 25GB)에서 확인한 기록. laurio 저장소·CI·staging·production 과 무관한 독립 디렉터리다.

## 구조

```
브라우저(xterm.js) ──http/ws 127.0.0.1:7777 (Bearer 토큰)──▶ infra-agent 컨테이너 ──/var/run/docker.sock──▶ 호스트 Docker
                                                              ├─ infralab-localstack   (localstack/localstack:4, 네트워크 alias "localstack")
                                                              ├─ infralab-workstation  (alpine + aws-cli v2 + kubectl + terraform, docker exec 로 터미널)
                                                              └─ kind 노드 컨테이너     (infralab-control-plane, infralab-worker, infralab-worker2)
```

- `agent/` — Go 단일 바이너리(creack/pty + gorilla/websocket) → alpine 이미지에 docker-cli·kind·kubectl 동봉
- `workstation/` — 학생이 들어가는 작업 컨테이너 이미지
- `run.sh build|up|down` — 빌드, 에이전트 기동(학생 설치 명령과 같은 형태), 정리

## 실행

```bash
bash run.sh build
AGENT_TOKEN=poc-token bash run.sh up        # http://127.0.0.1:7777/?token=poc-token
bash run.sh down                            # 환경·에이전트 전부 제거(이미지는 남김)
```

API: `GET /api/status`, `POST /api/env/up|down`, `POST /api/kind/up {"control_planes":1,"workers":2}`,
`POST /api/kind/down`, `GET /api/grade/{s3-site|k8s-basic}`, `WS /ws/terminal?token=`.

## 검증 결과 — 전부 통과

| 항목 | 결과 |
| --- | --- |
| 에이전트 컨테이너가 docker.sock 으로 호스트 Docker 제어 | OK (Docker Desktop 의 `/var/run/docker.sock` 마운트 그대로 동작) |
| `env/up` — 네트워크 + LocalStack + workstation 기동, 헬스 대기 | OK, 11초 (이미지 미리 받은 상태) |
| S3 과제(버킷·버저닝·index.html·웹호스팅) 채점 | 과제 전 0/4 → 학생이 aws cli 로 수행 후 4/4 |
| `kind/up` — 에이전트 **컨테이너 안에서** kind 로 1 cp + 2 worker 생성 | OK, 93초. `kind get kubeconfig --internal` 을 workstation 에 넣고 `kind` 네트워크에 붙이면 kubectl 통함 |
| k8s 과제(Deployment web 2 레플리카 + Service) 채점 | 과제 전 1/3 → 3/3 (파드가 두 worker 에 하나씩 스케줄됨) |
| 브라우저 xterm.js ↔ WebSocket ↔ pty ↔ `docker exec -it` | OK — 명령 입력·출력·프롬프트·resize 모두 동작 (`terminal.png`) |
| 공개 https 페이지(example.com) → `http://127.0.0.1:7777` fetch | OK 200 — CORS 허용 오리진 + `Access-Control-Allow-Private-Network: true` 응답 |
| 공개 https 페이지 → `ws://127.0.0.1:7777` WebSocket | OK — localhost 는 혼합 콘텐츠 예외라 ws:// 허용, 첫 프레임에 셸 프롬프트 수신 |
| 토큰 없는 요청 | 401. 포트는 127.0.0.1 에만 바인딩 |
| 에이전트 재기동 뒤 기존 kind 클러스터 | 노드가 호스트 컨테이너라 살아남음. `kind/up` 재호출이 "exists" 로 kubeconfig 만 다시 주입 |

메모리(docker stats, 과제 완료 상태): control-plane 559MB, worker 각 163MB, LocalStack 142MB(유휴),
workstation 6MB, agent 11MB — 합계 약 1GB. LocalStack 은 서비스를 쓰기 시작하면 더 오른다.

## 검증하지 않은 것 / 주의

- **실제 Chrome 의 Local Network Access 권한 프롬프트** — 검증은 Playwright Chromium 으로 했다. 최신 Chrome 은
  공개 사이트가 localhost 에 처음 접근할 때 사용자에게 허용 프롬프트를 띄운다(헤더는 이미 응답하고 있음).
  대시보드 안내문에 「허용」을 누르라는 설명이 필요하다. Safari 는 미검증.
- 과제 파일을 학생 로컬 에디터로 편집하는 호스트 볼륨 마운트는 넣지 않았다(에이전트는 호스트 경로를 모른다 —
  설치 명령에서 `-e HOST_WORK_DIR=...` 로 받아야 한다).
- Lambda 실행(LocalStack 이 docker.sock 으로 컨테이너를 띄움)은 마운트·`LAMBDA_DOCKER_NETWORK` 만 넣고 실제로 돌려 보지 않았다.
- Terraform 은 설치만 확인(v1.17.0), localstack/kind provider 시나리오는 미실행.
- kind 의 `kubectl` 컨텍스트는 에이전트 컨테이너 안 `/root/.kube` 에 남는다. 에이전트를 지우면 사라지지만 위 표대로 복구된다.
- 이미지 크기: localstack 1.77GB, kindest/node 약 1GB — 학생 첫 실행 때 받는 시간을 안내해야 한다.
