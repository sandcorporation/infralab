# Claude Code·Codex 세션 파일 형식 (2026-10-23)

에이전트 `/api/ai-transcript` 가 읽는 파일. 두 도구 모두 형식을 바꿀 수 있어서, 못 읽으면 그 도구만 `error` 로 돌려준다(500 아님).

## Claude Code 2.1.309 — 실측 (workstation 컨테이너)

- 위치: `/root/.claude/projects/<작업 디렉터리 경로의 / 를 - 로>/<세션 uuid>.jsonl`. `/work` 에서 띄우면 `-work/`. 서브에이전트는 `…/subagents/` 아래.
- 로그인 없이 `claude -p "say hi"` 를 `/work` 에서 돌려 만든 파일로 확인했다(`Not logged in · Please run /login`). 같은 버전(2.1.309)의 호스트 세션 파일 구조와 일치한다.
- 한 줄 = JSON 객체 하나. 발화는 `type` 이 `user` / `assistant` 인 줄뿐이다. 그 밖의 type: `attachment`, `system`, `queue-operation`, `api-request*`, `last-prompt`, `ai-title`, `file-history-*`, `cost-state` 등은 건너뛴다.
  - `timestamp`: ISO 8601 ms, UTC (`2026-10-23T07:11:43.433Z`)
  - `message.role`: type 과 같다. `isSidechain`: 서브에이전트 줄이면 true. `isMeta`: 메타 줄.
  - 학생이 친 프롬프트: `type:"user"`, `message.content` 가 **문자열**(`promptSource`·`turnOrigin` 같은 필드가 붙는다).
  - 도구 결과: `type:"user"` 이지만 `message.content` 가 `[{type:"tool_result",…}]` — 뺀다.
  - 어시스턴트: 블록 하나당 한 줄. `message.content` 가 `[{type:"text",text}]`(쓴다) / `[{type:"thinking"}]` / `[{type:"tool_use"}]`(뺀다).
  - 로그인 실패 같은 합성 오류는 `type:"assistant"` + `isApiErrorMessage:true` — 뺀다.
  - 사용자 줄 안의 `<system-reminder>`·`<local-command-*>`·`<command-name>` 래퍼 텍스트는 뺀다.

## Codex CLI 0.164.0 / 0.160.1 — 부분 실측

- 위치(호스트 0.160.1 에서 확인): `~/.codex/sessions/YYYY/MM/DD/rollout-<시각>-<uuid>.jsonl`. 오래된 파일은 `.jsonl.zst` 로 압축되어 있다(읽지 않는다).
- 한 줄 = `{timestamp, type, payload}`. 발화는 `type:"response_item"`, `payload.type:"message"`:
  - `payload.role`: `user` / `assistant` / `developer`(뺀다)
  - `payload.content`: `[{type:"input_text"|"output_text", text}]`
  - `user` 로 먼저 주입되는 문맥(`<environment_context>`, `# AGENTS.md instructions for …`, `<turn_aborted>` …)은 학생의 말이 아니므로 뺀다.
  - `reasoning`, `function_call*`, `custom_tool_call*`, `event_msg`(발화의 중복 사본), `turn_context`, `token_*` 은 뺀다.
- **실측 미완**: workstation 의 Codex 0.164.0 은 로그인 없이는 세션 파일을 만들지 않았다(`codex exec --skip-git-repo-check` 로 시도, 홈에 `*.sqlite` 만 생기고 rollout `.jsonl` 없음). 형식은 호스트의 0.160.1 기록과 CLI 출력 기준이며, 로그인한 0.164.0 에서의 확인은 남아 있다.

## 읽는 방법

1. `~/.infralab/<scenario_id>.prepared` 의 UTC 시각(환경 준비 때 에이전트가 쓴다)을 읽는다. 없으면 404 「환경 준비 먼저」.
2. 표시보다 나중에 바뀐 세션 파일만 `find … -newer <표시>` 로 찾는다(`/root/.claude/projects` 의 `*.jsonl`, `/root/.codex/sessions` 의 `rollout-*.jsonl`).
3. 각 파일을 `docker exec … cat` 으로 읽어 표시 시각 이후의 사용자·어시스턴트 텍스트만 시간순으로 모은다. 마지막 줄이 쓰다 만 것이면 건너뛰고, 그 밖의 JSON 아닌 줄은 그 도구의 `error` 다.
4. 두 도구 합계 200KB(발화 하나는 32KB)를 넘으면 오래된 것부터 버리고 `truncated`.
