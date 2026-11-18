# infra-agent

학생 PC 에서 docker.sock 으로 호스트 Docker 를 제어하는 Go 단일 바이너리. compose 가 올린
workstation·Floci 를 찾고, kind 클러스터를 올리고 내리며, 브라우저 터미널을 `docker exec` 로 중계한다.
서버 주소도 서버 자격증명도 모른다 — 브라우저가 중간에서 옮긴다.

## 환경변수 (compose.yml 이 넘긴다)

| 변수 | 기본값 | 뜻 |
| --- | --- | --- |
| `AGENT_TOKEN` | (필수) | 모든 API 의 `Authorization: Bearer` 토큰, 터미널 WS 의 `?token=` |
| `AGENT_ALLOWED_ORIGINS` | `http://127.0.0.1:5173,http://localhost:5173` | 콤마로 구분한 대시보드 오리진. 여기 든 Origin 에만 CORS·`Access-Control-Allow-Private-Network` 헤더를 준다 |
| `AGENT_LOCAL_LLM_URL` | (없음) | 지원자 PC 의 로컬 LLM(OpenAI 호환, 예 `http://host.docker.internal:11434`). 있으면 `POST /llm/v1/chat/completions` 가 `<값>/v1/chat/completions` 로 중계하고 대화를 `/api/ai-transcript` 에 `local_llm` 으로 남긴다. 없으면 중계는 502 |
| `AGENT_ADDR` | `:7777` | 리슨 주소. 127.0.0.1 바인딩은 compose 의 포트 매핑이 한다 |
| `WORKSTATION_CONTAINER` | `infralab-workstation` | 학생이 들어가는 작업 컨테이너 이름 |
| `FLOCI_CONTAINER` | `infralab-floci` | AWS 에뮬레이터 컨테이너 이름 |
| `KIND_CLUSTER` | `infralab` | kind 클러스터 이름 |

## API

- `GET /api/status` — `version`, `docker_server`, `workstation`·`floci` 상태(`running` / `exited` / `missing` …), `kind_nodes`. Docker 데몬에 닿지 못하면 `docker_error` 가 함께 온다
- `POST /api/kind/up {"control_planes":1,"workers":2}` — 단계별 결과(`steps`)와 `ok`. 클러스터가 이미 있고 노드 수가 같으면
  kubeconfig 만 다시 넣고, 노드 수가 다르면 지우고 다시 만든다. 노드 수 상한(control-plane 3, worker 5)을 넘으면 400
- `POST /api/kind/down` — `steps`·`ok`
- `POST /api/floci/reset` — compose 가 만든 Floci 컨테이너를 같은 설정(이미지·entrypoint/cmd·환경·라벨·bind/named 마운트·
  포트·privileged·재시작 정책·네트워크·별칭)으로 다시 만들어 상태를 비운다(익명 볼륨은 버린다). Floci 의 healthcheck 로
  준비를 기다린다. 단계별 결과(`steps`)와 `ok`
- `POST /api/check {"checks":[{id,name,hint,command,timeout_seconds,expect},…],"scripts":{"name.sh":"본문"}}` — 각 명령을
  workstation 에서 `bash -lc` 로(작업 폴더 `/work`) 돌리고 검사별 `pass`·`output`(stdout+stderr, 8KiB 상한·`truncated`)·
  `exit_code`·`ms`·`error` 를 돌려준다. `expect.type` 은 `exit_zero` / `equals{value}` / `contains{value}` /
  `regex{pattern}` / `jsonpath{path, equals|min|contains}` (path 는 `.a.b[0].c` 꼴). 보조 스크립트는
  요청마다 새 디렉터리 `/opt/infralab/checks/<nonce>/` 에 넣고 PATH 에 올려 명령에서 이름으로 부르며, 끝나면 지운다.
  정의가 하나라도 틀리면 400 이고 아무것도 돌리지 않는다. workstation 이 떠 있지 않으면 503(「전부 실패」가 아니라
  「채점 불가」). 검사 하나가 시간을 넘기면(안쪽 `timeout` + 바깥 컨텍스트) 그 검사만 `error` 로 실패하고 다음으로
  간다. 도커 자체의 실패(컨테이너 없음 등)도 `error` 로 구분한다 — `pass:false` 에 `error` 가 비어 있을 때만 학생이 틀린 것이다
- `POST /api/setup {"scenario_id","reset":{"floci":bool,"kind":{"control_planes","workers"}|null},"setup":{"command","scripts","timeout_seconds"}|null,"ai_rules":"본문"}` —
  「환경 준비」. 단계 순서: `floci/*`(reset.floci, `/api/floci/reset` 과 같은 코드) → `kind/*`(reset.kind — 클러스터가 이미
  맞게 있어도 **항상** 지우고 만든다) → `rules`(workstation `/work/CLAUDE.md`·`/work/AGENTS.md` 에 같은 본문) → `setup`(있으면 — 검사와 같은 실행기: 요청별 스크립트
  디렉터리·PATH·안쪽 `timeout`, 기본 30초·최대 300초) → `mark`(모든 단계가 성공한 뒤에만, 준비한 `/work` 의 `/work/.infralab/<scenario_id>.prepared` 에 UTC 시각 — 홈 볼륨(`/root`)은 기수마다 다른 compose 폴더가 이어 쓰므로 거기 두지 않는다 `2006-01-02T15:04:05Z`. 시작할 때 옛 표시를 먼저 지운다 — setup 이 실패하면 표시가 없어 채점이 열리지 않는다).
  단계별 `steps`·`ok` 를 돌려주고 앞 단계가 실패하면 뒤는 돌리지 않는다.
  setup 이 비정상 종료·시간 초과면 `ok:false` 이고 그 단계 결과에 출력이 남는다. scenario_id 는 소문자·숫자·하이픈, 노드 수 상한은
  kind up 과 같다(400). workstation 이 떠 있지 않으면 503, 환경 작업 중이면 409
- `GET /api/prepared?scenario_id=` — 준비 표시 파일이 있는지만 본다(`test -f`). 있으면 200 `{prepared:true}`, 없으면 404 `환경 준비 먼저`, workstation·도커 장애는 503. 화면이 채점 잠금을 정할 때 쓴다(기록 본문은 제출 때만 읽는다)
- `GET /api/ai-transcript?scenario_id=` — 마지막 환경 준비(`/api/setup` 의 준비 표시) 이후 workstation 안 Claude Code·Codex 의
  사용자·어시스턴트 텍스트 발화. 준비 표시가 없으면 404 `환경 준비 먼저`(화면이 「준비 전」으로 읽는다). 응답
  `{scenario_id, since, transcripts:[{tool:"claude"|"codex", since, truncated, error?, entries:[{role, at, text}]}]}` — 도구마다 항목이
  하나씩 온다. 도구 호출·결과·사고·시스템 메시지는 뺀다. 두 도구 합계 200KB(발화 하나 32KB)를 넘으면 오래된 것부터 버리고
  `truncated`. 한 도구의 세션 파일을 못 읽으면 그 도구만 빈 `entries` + `error`(200). 읽기 전용이라 환경 작업 잠금과 무관하다.
  파일 위치·형식은 `docs/ai-session-formats-2026-10-23.md`
- `GET /api/preflight` — 응시 전 점검. `{ok, checks:[{id, ok, message, help_url}]}` 이고 `checks` 는 늘 `engine`·`linux_mode`·`permission`
  순서다. `engine`·`permission` 은 `docker version` 으로 본다(실패하면 엔진 꺼짐, 실패 출력에 `permission denied` 가 있으면 권한
  실패), `linux_mode` 는 `docker info --format {{.OSType}}` 이 `linux` 인지 본다. 엔진에 닿지 못하면 확인하지 못한 항목도 원인을
  가리키는 실패로 온다. 실패한 항목은 `message`·`help_url` 이 비지 않고, 모두 통과해야 `ok:true`. 시험 응시 화면은 실패나
  무응답이면 「시작」을 막고, 연습 화면은 경고만 보인다. 읽기 전용이라 환경 작업 잠금과 무관하다
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

## 통합 시험 (실제 Docker, 손으로만)

`integration` 빌드 태그로 분리돼 기본 `go test` 에는 들어가지 않는다. 떠 있는 에이전트(학생 compose 스택)를 HTTP 로
친다: status → 준비 전 기록 404 → 환경 준비(`/api/setup`: Floci 초기화·규칙 파일 두 개·준비 표시·setup 산출물을 workstation 에서
확인) → 준비 뒤 기록 200(도구마다 하나) → 실패하는 setup(ok=false·출력) → s3 검사 0/4 → 과제 수행 → 4/4 → 스크립트 검사 →
kind up 두 번(두 번째는 exists) → kind down → Floci 초기화(버킷 사라짐) → 터미널 WS 에코. 세션 파일 형식과 두 고장 시나리오의
실측은 `docs/ai-session-formats-2026-10-23.md`, `docs/scenario-notes-2026-10-23.md`. 전제: 대시보드에서 받은 compose.yml 로 `docker compose up -d` 한 상태.
kind 노드 이미지가 있으면 3~5분, 처음이면 이미지(약 1GB)를 받느라 더 걸린다. 돌리는 동안 Floci 상태와 kind
클러스터가 지워진다.

```bash
AGENT_TOKEN=$(grep AGENT_TOKEN <compose 폴더>/compose.yml | sed 's/.*"\(.*\)"/\1/')
docker run --rm --add-host host.docker.internal:host-gateway -v "$PWD/agent:/src" -v infralab-gomod:/go/pkg/mod \
  -v infralab-gocache:/root/.cache/go-build -w /src -e AGENT_URL=http://host.docker.internal:7777 -e AGENT_TOKEN="$AGENT_TOKEN" \
  golang:1.23-alpine go test -tags integration -run Integration -v -count=1 -timeout 20m ./...
```
