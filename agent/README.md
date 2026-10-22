# infra-agent

학생 PC 에서 docker.sock 으로 호스트 Docker 를 제어하는 Go 단일 바이너리. compose 가 올린
workstation·Floci 를 찾고, kind 클러스터를 올리고 내리며, 브라우저 터미널을 `docker exec` 로 중계한다.
서버 주소도 서버 자격증명도 모른다 — 브라우저가 중간에서 옮긴다.

## 환경변수 (compose.yml 이 넘긴다)

| 변수 | 기본값 | 뜻 |
| --- | --- | --- |
| `AGENT_TOKEN` | (필수) | 모든 API 의 `Authorization: Bearer` 토큰, 터미널 WS 의 `?token=` |
| `AGENT_ALLOWED_ORIGINS` | `http://127.0.0.1:5173,http://localhost:5173` | 콤마로 구분한 대시보드 오리진. 여기 든 Origin 에만 CORS·`Access-Control-Allow-Private-Network` 헤더를 준다 |
| `AGENT_ADDR` | `:7777` | 리슨 주소. 127.0.0.1 바인딩은 compose 의 포트 매핑이 한다 |
| `WORKSTATION_CONTAINER` | `infralab-workstation` | 학생이 들어가는 작업 컨테이너 이름 |
| `FLOCI_CONTAINER` | `infralab-floci` | AWS 에뮬레이터 컨테이너 이름 |
| `KIND_CLUSTER` | `infralab` | kind 클러스터 이름 |

## API

- `GET /api/status` — `version`, `docker_server`, `workstation`·`floci` 상태(`running` / `exited` / `missing` …), `kind_nodes`. Docker 데몬에 닿지 못하면 `docker_error` 가 함께 온다
- `POST /api/kind/up {"control_planes":1,"workers":2}` — 단계별 결과(`steps`)와 `ok`. 클러스터가 이미 있으면 kubeconfig 만 다시 넣는다. 노드 수 상한(control-plane 3, worker 5)을 넘으면 400
- `POST /api/kind/down`
- `POST /api/check {"checks":[{id,name,hint,command,timeout_seconds,expect},…],"scripts":{"name.sh":"본문"}}` — 각 명령을
  workstation 에서 `bash -lc` 로(작업 폴더 `/work`) 돌리고 검사별 `pass`·`output`(stdout+stderr, 8KiB 상한·`truncated`)·
  `exit_code`·`ms`·`error` 를 돌려준다. `expect.type` 은 `exit_zero` / `equals{value}` / `contains{value}` /
  `regex{pattern}` / `jsonpath{path, equals|min|contains}` (path 는 `.a.b[0].c` 꼴). 보조 스크립트는
  요청마다 새 디렉터리 `/opt/infralab/checks/<nonce>/` 에 넣고 PATH 에 올려 명령에서 이름으로 부르며, 끝나면 지운다.
  정의가 하나라도 틀리면 400 이고 아무것도 돌리지 않는다. workstation 이 떠 있지 않으면 503(「전부 실패」가 아니라
  「채점 불가」). 검사 하나가 시간을 넘기면(안쪽 `timeout` + 바깥 컨텍스트) 그 검사만 `error` 로 실패하고 다음으로
  간다. 도커 자체의 실패(컨테이너 없음 등)도 `error` 로 구분한다 — `pass:false` 에 `error` 가 비어 있을 때만 학생이 틀린 것이다
- `WS /ws/terminal?token=` — 입력은 JSON 텍스트 프레임(`{t:"i",d}` 입력, `{t:"r",c,r}` 크기), 출력은 바이너리 프레임

환경을 바꾸는 작업(kind up/down)은 한 번에 하나만 돈다 — 돌고 있는 중에 들어온 요청은 409. 잘못된 메서드(GET 으로 kind/down 등)는 405.

## 구조

docker·kind 실행은 `Runner` 인터페이스(runner.go) 하나를 거친다. 핸들러는 그 인터페이스만 보고,
시험은 가짜 runner 를 끼워 HTTP 응답과 runner 에 넘어간 명령 인자를 본다. 터미널은 pty 가 필요해
runner 를 거치지 않는다 — 통합 시험으로 민다.

## 시험·빌드

Go 가 로컬에 없어도 Docker 의 Go 툴체인으로 돈다 (Windows Git Bash 는 `MSYS_NO_PATHCONV=1` 필요):

```bash
docker run --rm -v "$PWD/agent:/src" -v infralab-gomod:/go/pkg/mod -v infralab-gocache:/root/.cache/go-build \
  -w /src golang:1.23-alpine sh -c 'gofmt -l . ; go vet ./... && go test ./...'
```

이미지 빌드(버전은 `/api/status` 에 보인다):

```bash
docker build --build-arg VERSION=0.1.0-dev -t infralab/agent:dev agent/
```
