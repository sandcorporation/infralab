# infralab AI 프록시

시험 지원자의 Claude Code·Codex 와 공급사(Anthropic·OpenAI) 사이에 서는 Go 서비스(표준 라이브러리만 쓴다).
지원자는 응시 한 번짜리 **임시 토큰**을 들고 이 프록시를 공급사인 줄 알고 부른다. 진짜 공급사 키는 이 서비스만
환경변수로 갖는다(backend 도 갖지 않는다). 용어는 저장소 루트 `GLOSSARY.md` 의 「AI 프록시」「임시 토큰」.

요청 하나의 흐름:

1. 클라이언트가 들고 온 임시 토큰을 꺼낸다(아래 「경로」). 없으면 `unknown` 으로 막는다.
2. backend `POST /api/proxy/authorize`(`Authorization: Bearer <INFRALAB_EXAM_PROXY_SECRET>`, 본문
   `{token, tool, client_id}`)로 묻는다. 거절이면 공급사를 부르지 않고 공급사 꼴의 오류로 막는다.
3. 허용이면 요청 본문의 `model` 을 backend 가 준 **고정 모델**로 바꾸고, 인증 머리글을 진짜 공급사 키로 바꿔
   공급사로 넘긴다.
4. 공급사 응답(스트리밍 SSE 도)을 읽는 대로 조각마다 흘려 보낸다.
5. 응답이 끝나면 한 번, backend `POST /api/proxy/exchanges` 로 요청 본문(고정 모델로 바꾼 것)·응답 본문(SSE 면
   스트림 원문, 8 MiB 까지)·입출력 토큰 수를 넘긴다. 클라이언트가 중간에 끊어도 받은 만큼 기록한다.

## 경로

| 프록시 경로 | 도구(`tool`) | 공급사 경로 | 임시 토큰 |
|---|---|---|---|
| `POST /anthropic/v1/messages` | `claude_code` | Anthropic `/v1/messages` | `Authorization: Bearer <토큰>` 또는 `x-api-key: <토큰>` |
| `POST /anthropic/v1/messages/count_tokens` | `claude_code` | Anthropic `/v1/messages/count_tokens` | 위와 같음. Claude Code `/context` 가 부른다. 사용량으로 기록하지 않고 요청 수 한도에도 세지 않는다 |
| `POST /openai/v1/responses` | `codex` | OpenAI `/v1/responses` | `Authorization: Bearer <토큰>` |
| `POST /openai/v1/chat/completions` | `codex` | OpenAI `/v1/chat/completions` | `Authorization: Bearer <토큰>` |
| `GET /healthz` | — | — | — (`{"status":"ok"}`) |
| `GET /providers` | — | — | backend 전용, `Authorization: Bearer <공유 비밀>`. 공급사마다 키가 들어 있는지만 준다: `{"anthropic":true,"openai":false}`. 비밀이 틀리면 401 |

운영에서는 공개 포트 없이 web(nginx)의 `<도메인>/exam-proxy/` 가 접두어를 떼고 이 서비스로 넘긴다
(`web/nginx.conf`, 경로 시험 `scripts/check_exam_proxy_route.sh`). 그래서 `<프록시>` 는 `https://<도메인>/exam-proxy` 다.
Claude Code 는 `ANTHROPIC_BASE_URL=<프록시>/anthropic`, Codex 는 `base_url = "<프록시>/openai/v1"` 로 부른다
(backend 가 주는 「AI 키 설정」이 이 주소를 넣는다). 쿼리 문자열(`?beta=true` 등)과 그 밖의 머리글
(`anthropic-version`·`anthropic-beta` 등)은 그대로 넘긴다. 다른 경로는 404.

입출력 토큰 수는 응답의 `usage` 에서 읽는다: Anthropic `input_tokens`(+ `cache_creation_input_tokens`·
`cache_read_input_tokens`)·`output_tokens`, OpenAI chat `prompt_tokens`·`completion_tokens`, responses
`input_tokens`·`output_tokens`. 스트리밍이면 사건들(`message_start`·`message_delta`·`response.completed`, chat 의
`usage` 조각)에서 가장 큰 값.

## 거절 → 응답

임시 토큰마다 요청 수 한도(`INFRALAB_PROXY_TOKEN_PER_MINUTE`·`_BURST`)가 있다. 넘으면 backend 에 묻지도 않고
429 `rate_limited`(`Retry-After: 1`)로 막는다.

| backend `reason` | 상태 |
|---|---|
| `unknown`, `revoked` | 401 |
| `outside_window`, `tool_not_allowed`, `in_use_elsewhere` | 403 |
| `limit` | 429 |

본문은 공급사 꼴이다. Anthropic: `{"type":"error","error":{"type":"authentication_error|permission_error|rate_limit_error","message":…,"code":"<reason>"}}`,
OpenAI: `{"error":{"message":…,"type":…,"code":"<reason>","param":null}}`. backend 에 닿지 못하거나 backend 가 200 이
아니면 502(공급사도 부르지 않는다), 공급사에 닿지 못하면 502.

공급사 키는 하나만 있어도(둘 다 없어도) 뜬다. 키가 빈 공급사의 경로는 임시 토큰·backend 를 보기 전에
503 `provider_not_configured` 로 막는다 — 공급사도 backend 도 부르지 않고 사용량에 세지 않는다.

## `client_id` 규칙

`client_id` 는 요청의 **원격 주소 IP**(포트를 뺀 것)다. 같은 PC 의 Claude Code·Codex 는 같은 주소로 보이므로 한
클라이언트로 친다. backend 는 마지막 사용 5분 안에 다른 `client_id` 가 같은 토큰을 쓰면 `in_use_elsewhere` 로
막는다. 앞에 역프록시(Caddy 등)가 있으면 원격 주소가 늘 역프록시라 `INFRALAB_PROXY_TRUST_FORWARDED=1` 로
`X-Forwarded-For` 의 첫 주소를 쓴다 — 이 머리글을 덮어쓰는 역프록시 뒤에서만 켠다(아니면 클라이언트가 꾸밀 수 있다).

## 환경변수

| 이름 | 기본 | 뜻 |
|---|---|---|
| `INFRALAB_EXAM_PROXY_SECRET` | (필수) | backend 와 나누는 공유 비밀. backend 의 같은 이름 값과 같아야 한다. |
| `INFRALAB_ANTHROPIC_EXAM_KEY` | — | 진짜 Anthropic 키. |
| `INFRALAB_OPENAI_EXAM_KEY` | — | 진짜 OpenAI 키. |
| `INFRALAB_PROXY_BACKEND_URL` | `http://127.0.0.1:8000` | backend 주소(`/api/proxy/…` 가 붙는다). |
| `INFRALAB_PROXY_ADDR` | `:58090` | 듣는 주소. backend `INFRALAB_EXAM_PROXY_URL` 의 기본(`http://127.0.0.1:58090`)과 맞춘다. |
| `INFRALAB_PROXY_FAKE_PROVIDER` | — | `1` 이면 가짜 공급사 모드(아래). |
| `INFRALAB_PROXY_TRUST_FORWARDED` | — | `1` 이면 `client_id` 를 `X-Forwarded-For` 첫 주소로. |
| `INFRALAB_PROXY_TOKEN_PER_MINUTE` | `120` | 임시 토큰마다 분당 요청 수(토큰 버킷). `0` 이면 제한 없음. |
| `INFRALAB_PROXY_TOKEN_BURST` | `60` | 임시 토큰마다 한꺼번에 쓸 수 있는 요청 수. |
| `INFRALAB_PROXY_ANTHROPIC_URL` | `https://api.anthropic.com` | Anthropic 주소(바꿀 일은 거의 없다). |
| `INFRALAB_PROXY_OPENAI_URL` | `https://api.openai.com` | OpenAI 주소. |

비밀(공유 비밀·공급사 키)은 환경변수에서만 오고, 응답·로그에 찍지 않는다. 로그에는 경로·도구·고정 모델·
`client_id`·상태·토큰 수·거절 사유만 남고 임시 토큰도 찍지 않는다.

## 가짜 공급사 모드

`INFRALAB_PROXY_FAKE_PROVIDER=1` 이면 프로세스 안 `127.0.0.1` 임시 포트에 가짜 공급사를 띄우고 공급사 주소를
그쪽으로 돌린다. 진짜 키·네트워크 없이 세 경로 모두(스트리밍 포함) 결정적 응답 `infralab fake provider reply.` 와
사용량(입력 = 요청 본문 바이트 / 4 + 1, 출력 = 7)을 준다. 진짜 공급사 키가 있어도 쓰지 않는다. 시험·CI·dev 에서 쓴다.

## 실행·시험

```sh
cd proxy
go test ./...                          # 가짜 backend(httptest)·가짜 공급사로 시험, 네트워크 없음
INFRALAB_EXAM_PROXY_SECRET=dev INFRALAB_PROXY_FAKE_PROVIDER=1 go run .
docker build -t infralab-proxy proxy/  # 저장소 루트에서
```

`scripts/ci.sh agent` 가 agent 와 함께 이 모듈도 gofmt·vet·test 한다(Go 판은 `agent/go.mod` 와 같게).
