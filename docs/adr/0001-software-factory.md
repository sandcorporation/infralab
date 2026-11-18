# 0001. 소프트웨어 공장: spec 에서 병합까지 GitHub Actions 안에서

- 상태: 채택. secret `CLAUDE_OAUTH_TOKEN` 이 없으면 모든 공장 run 이 첫 job(`token`)에서 멈춘다. 첫 run 은 조율자가 켠다(아래 「켜는 순서」).
- 날짜: 2026-11-18 (#47, 상위 spec #45)
- 원본: 같은 조직의 다른 공개 저장소(Rust·Windows 데스크톱 앱)가 쓰던 공장과 그 ADR. 흐름·스크립트·장부·알림 다리를 그대로 들이고, 스택에 걸린 부분만 바꿨다(맨 아래 「원본에서 바꾼 것」).

## 맥락

infralab 은 backend(Django·pytest), web(React·vitest), agent(Go) 세 부분이다. spec(#45)이 크고 티켓이 많아, 사람이 티켓마다 구현·검토·병합하면 느리다. 공장은 spec 을 티켓과 **먼저 고정한 인수 시험**으로 쪼개고, 티켓마다 에이전트가 구현하고, 다른 run 이 검사해 병합한다. 자동 검사는 #46 의 `scripts/ci.sh all` 하나다.

## 결정

### 서비스

| 서비스 | 제품 |
| --- | --- |
| Ticket tracker | GitHub Issues (라벨은 `docs/agents/triage-labels.md`) |
| Orchestrator | GitHub Actions (`.github/workflows/factory-*.yml`) |
| Runner | 모두 `ubuntu-latest` |
| 에이전트 | `anthropics/claude-code-action@v1`, 인증은 구독 OAuth 토큰(secret `CLAUDE_OAUTH_TOKEN`) |
| PR·push·병합 토큰 | 조직 GitHub App `sandcorp-factory`(variable `FACTORY_APP_ID`, secret `FACTORY_APP_PRIVATE_KEY`). 브랜치 push(`app-push.sh`)·PR 열기·병합(`merge-pr.sh` → `scripts/pr-merge.sh`)만 이 토큰(contents·pull-requests 쓰기, workflows 없음). 라벨·댓글·이슈·dispatch 는 `GITHUB_TOKEN` — App 이 라벨을 달면 issues 이벤트가 공장 run 을 다시 깨운다(#172) |
| 병합 문 | main ruleset: ci.yml 필수 잡(backend·web·agent·exam-proxy-route·factory) 초록, 예외(bypass) 없음. App 의 push 라 공장 PR 에도 ci.yml 이 돈다(#172) |
| 자동 검사 | `scripts/ci.sh all` (backend pytest + Postgres 서비스, web typecheck·vitest·build, agent gofmt·vet·test, 공장 스크립트 시험) |
| 장부·원장 | 이슈와 댓글. `specs/` 폴더는 두지 않는다 |

### Task

| Task | Trigger | 하는 일 | 다음 |
| --- | --- | --- | --- |
| Decompose (`factory-decompose.yml`, Opus) | `spec` 라벨, 수동 실행, 재개 | 새 spec 이면 하위 이슈(티켓)·blocked-by·`model:*` 라벨을 만들고 티켓별 인수 시험을 꺼 둔 채 쓴다(아래 「인수 시험」). 해법이 갈리면 `<!-- factory-question -->` 댓글과 `needs-decision` 을 남기고 멈춘다. 지시 `.github/factory/decompose.md` | `factory/spec-<S>` 에 시험만 커밋해 스펙 PR(`spec-pr`)을 열고 Odin 을 dispatch |
| Odin (`factory-odin.yml`, Opus) | Decompose·재개의 dispatch | 스펙 PR 에 main 을 merge(충돌은 같은 run 의 에이전트가 양쪽을 남겨 푼다)하고, 티켓·시험을 코드·앞 spec 의 시험·ADR 과 대조해 고친다. 계약의 아직 없는 이름은 `#<티켓>` 스텁으로 둔다. `scripts/ci.sh all` 뒤 인수 탐침(`acceptance-probe.sh`, #212)이 이 PR 의 인수 시험을 한 번 켜 돌려, 단언·스텁이 아닌 제 오류(수집·import·빌드 오류, ConstructorError 같은 예외, panic)로 빨간 시험을 검사 실패로 친다. 둘 중 하나라도 실패하면 한 번 더 고칠 기회. 지시 `.github/factory/odin.md` | 스펙 PR squash 병합, 열린 티켓에 `ready-for-agent`, 사슬 시작. 두 번 실패·충돌 한도(2) 초과면 spec 에 `ready-for-human` |
| Implementer (`factory-implementer.yml`, 라벨대로 Sonnet/Opus) | `ready-for-agent` 라벨, 티켓 닫힘(`frontier`), 수동 실행, 매일 KST 00:05 | 열린 blocker 가 없을 때만. 자기 티켓의 시험을 켜고 스텁을 구현한다. workflow 가 `scripts/ci.sh all`(실패면 한 번 고칠 기회) 뒤 push·PR(`Closes #N`, `<!-- factory-checked <sha> -->`). **병합하지 않는다.** 충돌로 되돌아온 티켓은 열린 PR 에 main 을 merge 해 풀기만 한다(충돌 모드). 지시 `.github/factory/implementer.md` | Verify dispatch, 빈 트랙 채우기. 코드 실패 2번·인프라 실패 3번이면 `ready-for-human`. 에이전트가 `<!-- factory-implementer-blocked -->` 댓글을 남겼거나 커밋 없이 run 중에 까닭 댓글을 남기면(#212) 실패로 세지 않고 곧바로 `ready-for-human`(`record-failure.sh`) |
| Verify (`factory-verify.yml`, Sonnet) | Implementer·재개의 dispatch | 기계 검사(`verify.sh mech`), main 을 merge 한 뒤 `scripts/ci.sh all`(머리가 검사한 커밋 그대로면 건너뜀), 인수 판단. 지시 `.github/factory/verify.md` | 통과: ci.yml 필수 잡 초록을 기다려 App 으로 squash 병합(빨강·미완료면 인수 실패로 되돌림)·티켓 닫기·다음 티켓. 병합이 App 의 main push 라 `release.yml`(검사·이미지·production 승격, docs/ops/deploy.md)은 그 push 로 돈다. 실패: `<!-- factory-sendback kind=acceptance|conflict -->` 로 되돌림(인수 2번·충돌 3번이면 `ready-for-human`) |
| 재개 (`factory-resume.yml`) | spec 에서 `needs-decision`·`factory-paused` 를 뗄 때, 수동 실행 | `resume.sh` 가 멈춘 단계를 정해 dispatch | 그 단계 |

**사람이 손으로 만든 티켓**(spec 없이, 인수 시험 없이)도 `ready-for-agent` 를 붙이면 Implementer 가 받는다. 그때 인수 기준은 티켓 본문의 체크리스트이고, 시험은 구현 run 이 일반 시험 파일에 쓴다. 기계 검사는 표식·스텁이 없으므로 그냥 통과하고 Verify 의 인수 판단이 체크리스트를 본다.

### 인수 시험

티켓마다 시험 함수 하나하나가 **표식 한 줄로 꺼져** main 에 들어간다. 구현 run 은 그 표식만 걷어 시험을 켜고, 다른 줄은 고치지 못한다(`verify.sh mech` 가 기계로 막는다). 규칙의 원본은 `.github/factory/spec-tests.sh`.

| 부분 | 파일 | 꺼 두는 표식 | 켤 때 | 스텁 |
| --- | --- | --- | --- | --- |
| backend | `backend/tests/test_spec_<slug>_<group>.py` | 시험 바로 위 `@pytest.mark.skip(reason="#N")` | 줄을 지운다 | `raise NotImplementedError("#N")` |
| web | `web/src/spec/spec_<slug>_<group>.test.ts(x)` | `it.skip(…) => { // #N` (또는 `test.skip(`) | 같은 줄에서 `.skip` 과 끝의 `// #N` 만 지운다 | `throw new Error("#N")` |
| agent | `agent/spec_<slug>_<group>_test.go` | 시험의 첫 줄 `t.Skip("#N")` | 줄을 지운다 | `panic("#N")` |

- backend 파일 이름이 `test_` 로 시작하는 것은 pytest 수집 규칙(`python_files = ["test_*.py"]`) 때문이다.
- 꺼 둔 시험도 import·컴파일은 되므로 Odin 의 스텁이 있어야 main 의 `scripts/ci.sh all` 이 초록이다. 이것이 원본의 「clippy 로 컴파일 확인」 자리다.
- 꺼 둔 시험이 **옳은 까닭으로 빨강인지**는 Odin 의 인수 탐침(`.github/factory/acceptance-probe.sh`, #212)이 본다: 표식을 걷어 한 번 돌리고, 실패가 단언(pytest `AssertionError`·`pytest.fail`, vitest `AssertionError`·`.resolves`/`.rejects` 실패, Go `t.Error`/`t.Fatal`)이나 그 티켓의 스텁이면 통과, 그 밖의 예외·수집/import/빌드 오류·fixture 오류·panic 이면 검사 실패다. #194 는 Odin 이 쓴 시험이 compose `!reset` 을 `yaml.safe_load` 로 읽다 `ConstructorError` 로 빨강이라 구현과 상관없이 통과할 수 없었고, Implementer 가 같은 진단으로 세 번 멈췄다. pytest 결과는 플러그인 `probe_pytest.py`(시험 `backend/tests/test_factory_probe_plugin.py`)가 예외 종류를 적는다.
- 공장 runner 는 Docker 시나리오를 실제로 돌리지 않는다. 인수 시험은 스키마·로직·HTTP 시험까지다. 브라우저·로컬 스택으로 돌릴 수 있는 기준(화면 동작·감독 신호·응시 흐름·터미널 입력)은 구현 run 이 `web/e2e/*.spec.ts`(`scripts/ci.sh e2e`) 시험으로 덮고, 사람만 확인할 수 있는 것(작업 PC 의 실제 실습 환경, 실제 AI 에이전트 세션)만 티켓의 「손 확인」·PR 본문 `사람 확인`으로 간다(#167).
- **사람 확인은 spec 을 붙잡는다**(#167, 장치): Verify 가 티켓 PR 을 병합할 때 PR 본문 `사람 확인` 항목을 spec 별 확인 이슈(라벨 `human-check`, 「사람 확인: spec #S」, `- [ ] 항목 (PR #x)`)에 쌓는다(`human-check.sh stack`, 같은 PR 은 한 번). 항목은 그 절의 목록 줄(`-`·`*`·`+`·번호·`- [ ]`)뿐이고 「없음」류는 항목이 아니다. 절은 다음 제목·HTML 주석·`Closes #`·가로줄·목록 뒤 빈 줄 다음 목록 아닌 줄에서 끝난다 — PR 꼬리(`Closes`·`_Opened by…_`·`factory-checked`)는 항목이 아니다(#183). 확인 이슈를 만들기 전 spec 에 `<!-- factory-human-check-issue -->`, 만든 뒤 `<!-- factory-human-check-issue N -->` 댓글을 남기고, gate 는 그 번호의 이슈를 직접 읽어 라벨 목록과 합친다 — 막 만든 이슈는 라벨 목록에 늦게 나와 spec #178 이 닫혔다(#183). 앞 표지는 있는데 확인 이슈를 못 찾으면 닫지 않는다. 확인 이슈는 sub-issue 도 `## Parent` 도 아니라 티켓으로 집히지 않는다. 티켓이 다 병합돼도 미체크 `- [ ]` 가 남아 있으면 `dispatch-next.sh` 가 spec 을 닫지 않고 실행 중인 spec 으로 센다(`FACTORY_TRACKS=1` 이면 다음 spec 도 기다린다). 처음 막힐 때 확인 이슈에 `<!-- factory-human-check S -->` 를 남기고(둘째 줄 `<!-- prs … -->` 에 알린 미체크 항목의 PR 번호) 다리가 대표(BRIDGE_TO_BOSS)에게 보낸다. 마커 뒤에 새 미체크 항목이 쌓이면 그 항목만 담아 한 번 더 남긴다(#170). 모두 체크하거나 확인 이슈를 닫으면 다음 dispatch 에 spec 이 닫힌다. 부모에 `spec` 라벨이 없으면(우산 이슈 #45 등) 확인 이슈를 만들지 않는다 — gate·닫기는 `spec` 라벨 이슈만 다루니 그 항목은 아무것도 붙잡지 못한다(#189, #173). Judge 는 「코드가 plainly implements」만으로 손 확인 기준을 충족으로 치지 않고, 브라우저로 돌릴 수 있는 기준이 e2e 시험 없이 `사람 확인`으로 오면 반려한다(verify.md).

### 모델 배정

Decompose·Odin 은 Opus, Verify 는 Sonnet, Implementer 는 티켓의 `model:sonnet`(기본)·`model:opus` 라벨대로 쓴다. Opus 는 동시성·권한과 인증·데이터 이전·비밀과 토큰(AI 프록시, 에이전트 토큰)·에이전트의 Docker 제어처럼 어려운 티켓이나 뒤 티켓이 따라 할 첫 인터페이스에만 붙인다. 코드 실패나 되돌림 뒤 다시 돌 때는 Opus 로 올리고, 인프라 실패는 같은 모델로 다시 돈다. **Fable 은 쓰지 않는다.**

### 트랙·사슬·장부·알림 (원본 그대로)

- **트랙**: 저장소 변수 `FACTORY_TRACKS`(없으면 2)만큼 Implementer 가 나란히 돈다. run 제목 `implement #N (track T)` 로 바쁜 트랙을 세고 빈 트랙에만 dispatch 한다. Verify 는 직렬(group `factory-verify`)이고 끝날 때마다 기다리는 PR 의 Verify 를 띄운다(`verify.sh next-verify`). `1` 이면 Implementer 와 Verify 가 한 줄이다.
- **spec 사슬**: 할 티켓이 없으면 하위 이슈가 다 닫힌 spec 을 닫고, 변수 `FACTORY_SPEC_QUEUE`(spec 번호를 순서대로, 비면 넘어가지 않음)의 다음 spec 에 `spec` 라벨을 붙여 Decompose 를 띄운다. 진행 중 티켓(`in-progress`·`ready-for-agent`, `local` 아님)은 라벨 검색이 늦게 따라오므로 하나씩 REST 로 다시 읽어 센다 — 방금 병합돼 닫힌 #179 가 「spec 밖 진행 중」으로 세어져 idle 표지가 빠졌다(#189). `--tickets-only` 실행(티켓 닫힘의 frontier)도 열린 spec·진행 중 티켓·라벨 안 받은 큐 spec 이 하나도 없으면 idle 표지를 남긴다(spec 은 옮기지 않는다).
- **되돌림 종류와 한도**: `kind=acceptance`(기계 검사·인수 판단·병합 실패: PR 을 닫고 main 부터 다시) 2번, `kind=conflict`(main 과 충돌·merge 뒤 검사 실패·push 실패: PR 을 두고 충돌 모드로 풀기) 3번이면 사람에게 넘긴다.
- **비용 장부와 상한**(`ledger.sh`): Claude 단계마다 `factory-ledger` 라벨의 장부 이슈에 비용 댓글. 시작 전 가드가 spec 합계(spec 본문의 `예산: $N` 줄 → 변수 `FACTORY_SPEC_BUDGET_USD` → $60)와 KST 하루 합계(`FACTORY_DAILY_BUDGET_USD` → $150)를 본다. 넘으면 `factory-paused` 또는 하루 멈춤, KST 00:05 예약 실행이 다시 시작한다.
- **알림 다리**(`bridge.sh`, #192): 공장은 메일을 보내지 않는다. 공장 밖 크론(2분)이 `gh` 로 저장소를 읽어 사람을 기다리는 것을 switchboard 메일함으로 한 번씩 보낸다. **기준은 라벨이다**: 열린 이슈의 `needs-decision`(질문)·`human-check`(확인 이슈, 본문에 미체크 `- [ ]` 가 있을 때만) → `BRIDGE_TO_BOSS`, `ready-for-human`(사람 넘김, `local` 이 함께면 로컬 작업자 몫)·`factory-paused`(spec 상한 멈춤) → `BRIDGE_TO_COORD` + `BRIDGE_CC`. (이슈, 라벨, 타임라인의 마지막 `labeled` 시각, 받는 곳)마다 한 번이라 뗐다 다시 붙이면 새 알림이다. 표식 댓글은 까닭으로만 인용한다(믿을 수 있는 작성자의 가장 최근 `<!-- factory-… -->`, 없으면 「까닭 댓글 없음」). 근본 원인: 「사람 기다림」이 라벨과 표식 댓글로 따로 놀았고 다리는 표식만 봐서, 표식 없이 라벨만 붙은 길(#166 구현 3회 실패 넘김)이 조용히 멈췄다. 라벨이 없는 종류만 표식 댓글 그대로: `factory-budget-daily`·`factory-queue-empty`·`factory-idle` → 조율자 + `BRIDGE_CC`, `factory-human-check S`(티켓이 다 병합됐는데 확인 이슈가 spec 을 붙잡음, #167) → 대장. idle 은 `FACTORY_SPEC_QUEUE` 가 있으면 다리가 직접도 본다(큐 spec 이 모두 닫히고 `ready-for-agent`·`in-progress` 0 → 큐 값마다 한 번, 표식과 같은 상태 줄이라 한 통). `ready-for-human` 을 붙이는 길은 `hand-to-human.sh` 하나다(까닭 댓글 `<!-- factory-human -->` 를 먼저 남기고 라벨을 붙인다): Implementer 실패 한도·막힘(`record-failure.sh`, `<!-- factory-implementer-blocked -->` 는 곧바로)·Verify 되돌림 한도·Odin·workflow-guard·local-ticket 이 모두 이것을 부르고, 다른 파일이 그 라벨을 붙이지 않는 것을 `tests/hand-to-human.sh` 가 grep 으로 고정한다. 사람이 티켓을 공장에 돌려줄 때 `<!-- factory-reset -->` 댓글을 남기면 그 앞 실패·되돌림은 세지 않는다(record-failure·verify·모델 고르기). 받는 곳 이름은 크론 환경변수로만 준다(스크립트에 기본값 없음): `BRIDGE_TO_COORD` 가 없으면 아무것도 보내지 않고(exit 2), `BRIDGE_TO_BOSS` 가 없으면 대장 몫만 잡아 두고(기억하지 않음, exit 1) 나머지는 보낸다. `BRIDGE_CC` 는 쉼표·공백 구분. 키는 라벨 `<저장소 이름>-factory-label-<n>-<라벨>-<시각>-<받는 곳>`, idle `…-factory-idle-<큐>-<받는 곳>`, 표식은 첫 받는 곳 `…-factory-<댓글 id>`·나머지 `…-<댓글 id>-cc-<받는 곳>`(#188 그대로). 상태 파일(`~/.local/state/<저장소 이름>-factory-bridge/sent`, `BRIDGE_STATE_DIR` 로 옮김)에 댓글 id 가 있으면 모든 받는 곳이 받은 것이다. 표식만 보던 다리의 상태 파일을 처음 읽는 실행은 그 다리가 이미 보낸 까닭 댓글을 가진 라벨을 보내지 않고 기억만 한 뒤 `labels-seeded` 줄을 남긴다(올릴 때 `--seed` 불필요). 스크립트에 주소·토큰·호스트·받는 곳 이름은 없고 메일 서버는 switchboard 프로필(`SWITCHBOARD_PROFILE`, 기본 `automation`)이 안다. 첫 설치는 `--seed`.
- **사람 넘김**(`ready-for-human`)은 「공장 밖에서 관리 세션이 처리」라는 뜻이다. 관리 세션이 원인을 고치거나 직접 구현하고, 대표에게는 제품 결정만 묻는다.

- **후보에서 빼는 것**(#56): `dispatch-next.sh` 는 `spec` 라벨이 있거나 하위 이슈(sub-issue)가 있는 이슈를 티켓으로 집지 않는다(부모는 티켓이 아니다).
- **장부는 스스로 만든다**(#56): `ledger.sh record` 는 열린 `factory-ledger` 이슈가 없으면 「공장 비용 장부」를 만들어 기록한다(비용을 버리지 않는다).
- **spec 귀속**(#56): 티켓의 부모는 GitHub sub-issue 의 parent(`GET /issues/{n}/parent`)를 먼저 보고, 없으면 본문 `## Parent` 절을 본다. 손으로 만든 티켓도 sub-issue 로 묶으면 spec 에 비용이 쌓인다.
- **`ready-for-agent` 는 부모가 있어야 한다**(#56, 장치): 이슈 템플릿 `.github/ISSUE_TEMPLATE/ticket.md` 가 `## Parent` 절을 깔고, `parent-check.sh`(`approved` job 과 claim 단계)가 부모 없는 티켓의 라벨을 떼고 「부모 spec 이 없다」 댓글(`<!-- factory-no-parent -->`)을 단다. 쓰기 권한이 없는 사람이 붙인 라벨은 보지 않는다.
- **workflow 티켓은 쪼갤 때부터 공장 밖으로**(#56): Decompose 는 `.github/workflows/` 를 바꿔야 하는 티켓에 `ready-for-human` + `local` 라벨과 「workflow 파일 — 로컬 작업자 몫」 한 줄을 단다(decompose.md). 붙인 결과는 `local-ticket.sh` 가 Decompose 직후·Odin 승인 전·implementer 의 `approved`/claim 에서 다시 확인해, 본문에 `<!-- factory-touches-workflows -->` 표식(또는 체크된 템플릿 줄 「workflow 파일을 바꾼다」)이 있는데 `ready-for-agent` 인 티켓을 같은 라벨로 바꿔 단다. 경로 문자열만 언급한 본문(「건드리지 않는다」)은 local 로 보지 않는다(#66); 표식이 빠져도 `workflow-guard.sh` 가 push 전에 멈춘다. `dispatch-next.sh` 는 `local` 티켓을 집지 않는다. workflows 권한 토큰(`FACTORY_WORKFLOW_TOKEN` 류)은 만들지 않는다.
- **workflow 파일은 사람 몫**(#56): 공장의 push 토큰은 `.github/workflows/*` 를 push 할 수 없다(#53 이 세 번 돌아 약 $8.2 를 버렸다. #172 부터 App 토큰도 workflows 권한 없이 만든다). `.claude/` 도 같다 — 공장 에이전트(Claude Code)는 그 아래 파일 편집을 민감 파일로 거부당한다(#166 이 세 번 실패), Decompose 는 `<!-- factory-touches-claude -->` 로 local 로 뗀다. implementer.md 는 workflow 를 고치지 말고 티켓 댓글로 남기고 멈추라 하고, 커밋 뒤 diff 에 `.github/workflows/` 가 있거나 push 가 그 거절을 내면 `workflow-guard.sh` 가 실패 횟수를 늘리지 않고 곧바로 `ready-for-human` + `<!-- factory-human -->`(사유: workflow 파일)로 넘긴다. 다시 dispatch 하지 않는다(6번을 빠져나온 경우의 안전망).

### 공개 저장소 규칙 (2026-11-18 공개 전환)

- **외부인은 공장을 움직이지 못한다.** 트리거는 라벨(`issues: labeled/unlabeled`, 라벨은 triage 이상 권한자만 붙인다), 이슈 닫힘(`frontier` 는 secret 없이 `ready-for-agent` 티켓만 dispatch), `workflow_dispatch`(쓰기 권한자), 예약 실행뿐이다. `pull_request_target`·`issue_comment` 트리거는 쓰지 않는다. 외부 PR 의 `ci.yml`(`pull_request`)은 secret 을 받지 않는다.
- 공장은 댓글을 트리거로 쓰지 않는다. 표식 댓글을 읽는 것은 공장 밖 `bridge.sh` 뿐이고, 그것도 `github-actions[bot]` 과 쓰기 권한자(admin·maintain·write)의 댓글만 보낸다.
- 공장 run 은 시험용 값(Postgres `infralab`/`infralab`, `DJANGO_SECRET_KEY=ci-only-insecure-key`) 말고 비밀을 쓰지 않는다. 실제 주소·호스트·토큰·내부 저장소 이름을 코드·이슈·PR·커밋에 넣지 않는다.
- `implement` 단계의 「Agent commands」는 에이전트가 돌린 명령 줄만 찍고 도구 출력은 찍지 않는다(공개 로그).

### 켜는 순서

1. **지금(#47 병합)**: workflow 는 main 에 있지만 secret 이 없어 어느 run 이든 `token` job 에서 「CLAUDE_OAUTH_TOKEN 없음」으로 멈춘다(1분 안). `token` 이 실패하면 뒤 job 이 건너뛰어지므로 runner 를 더 쓰지 않고, 사슬(`dispatch-next.sh`)도 돌지 않는다.
2. **대표가 등록한다**(Settings → Secrets and variables → Actions):
   - secret `CLAUDE_OAUTH_TOKEN` (`claude setup-token`). workflow 는 이것을 action 입력 `claude_code_oauth_token` 으로 넘긴다.
   - 변수 `FACTORY_TRACKS` — 처음엔 `1` 을 권한다(한 줄로 지켜본다).
   - 변수 `FACTORY_DAILY_BUDGET_USD`, `FACTORY_SPEC_BUDGET_USD` — 없으면 $150·$60.
   - 변수 `FACTORY_SPEC_QUEUE` — 처음엔 비워 둔다(라벨 붙인 spec 하나만 돈다).
3. **등록 전에 정할 것**: `ready-for-agent` 가 붙은 열린 손 티켓은 토큰을 넣은 뒤 첫 사슬 호출(티켓 닫힘·매일 KST 00:05 예약·다른 `ready-for-agent` 라벨)에서 Implementer 가 받는다. 공장에 맡기지 않을 티켓은 등록 전에 라벨을 뗀다.
4. **첫 시범**: 작은 spec 하나에 `spec` 라벨 → Decompose·Odin 을 지켜본 뒤 티켓 사슬. 그다음 `FACTORY_TRACKS`·`FACTORY_SPEC_QUEUE` 를 늘린다.
5. 알림 다리는 공장 밖 크론에 `bridge.sh --seed` 한 번 뒤 2분 간격으로 건다. 크론 줄에 `FACTORY_REPO`·`BRIDGE_TO_COORD`·`BRIDGE_TO_BOSS`(·`BRIDGE_CC`·`FACTORY_SPEC_QUEUE`)를 준다.

### 예상 runner 분

`scripts/ci.sh all` 은 #46 의 CI 에서 job 마다 30초 안팎(합쳐 약 1.5분, 설치 포함 2~3분)이다. job 한도와 근거:

| job | timeout | 근거 |
| --- | --- | --- |
| `token` (모든 공장 workflow) | 2분 | secret 하나 확인 |
| Decompose | 45분 | 빌드 없음. 에이전트 250턴(Opus) — spec #62(티켓 15개)가 120턴을 넘겨 실패한 뒤 올림 |
| Odin | 90분 | 충돌 풀기(40분 상한)·검토(60분 상한)·`ci.sh all` 최대 두 번(각 3분 안팎) |
| Implementer `implement` | 90분 | 에이전트 200턴 + `ci.sh all` 최대 두 번. 원본(Windows·Rust 빌드)의 180분에서 줄였다 |
| Implementer `frontier`·`approved`·`resume` | 기본 | `dispatch-next.sh` 만, 1~2분 |
| Verify | 45분 | `ci.sh all` 한 번 + 인수 판단 40분 상한 |
| 재개 | 10분 | 스크립트만 |

한 티켓은 보통 Implementer 20~40분 + Verify 5~15분 + `token` 두 번(각 1분) ≈ 30~60분, 최악(두 job 모두 한도) 약 140분이다. spec 하나는 여기에 Decompose 10~30분 + Odin 15~40분이 더 든다. 저장소가 공개로 바뀌어 표준 runner 분은 무료다.

## 결과

- 관리할 서버가 없다(알림 다리 크론만 공장 밖).
- 구독 OAuth 토큰을 쓰므로 공장 run 이 구독 사용량을 함께 쓴다.
- 공장 스크립트는 가짜 `gh`·`switchboard` 로 시험한다(`.github/factory/test.sh`, `scripts/ci.sh factory`, CI 의 `factory` job 이 actionlint 와 함께 돌린다). workflow 연결은 시범으로 확인한다.

## 원본에서 바꾼 것

- **러너**: Implementer·Odin·Verify 의 Windows 러너와 Claude Code 수동 설치(pwsh)를 `ubuntu-latest` 와 action 의 기본 설치로. Rust 빌드 캐시 대신 `.github/actions/factory-toolchain`(uv·Python·Node·Go, ci.yml 과 같은 판)과 job 의 Postgres 서비스.
- **자동 검사**: Rust 의 xtask 검사·포매터 검사·clippy 를 모두 `scripts/ci.sh all` 로. Odin 의 「컴파일 확인」도 같은 명령이다(꺼 둔 시험은 import·컴파일만 된다).
- **인수 시험·스텁**: Rust 시험 파일의 `#[ignore]` 표식·`todo!` 스텁을 위 「인수 시험」 표로. web 의 켜기는 줄 지우기가 아니라 줄 바꾸기라 `verify.sh mech` 가 「지운 표식 줄 → 같은 줄에서 `.skip`·`// #N` 만 뺀 줄」 짝을 허용한다.
- **secret 없음 멈춤**: 원본에 없던 `token` job 을 Claude 를 쓰는 workflow 마다 맨 앞에 둔다.
- **손 티켓**: 인수 시험 없는 티켓도 받는다(위).
- **뺀 것**: 벤치(`bench.yml`, `bench-gate.sh`, `factory-bench-regression` 표식과 알림 종류), Windows 빌드·nightly. Verify·Odin 의 병합 뒤 `release.yml` dispatch 는 운영 배포 경로(#53)와 함께 되살렸다가 App 병합의 push 이벤트로 바꿨다(#172), `.gitattributes` 의 CRLF 시험(Windows 전용), Explore task(원본도 꺼져 있다).
- **이름**: 봇 커밋 이름은 `github-actions[bot]`, 알림 다리의 저장소 기본값(`FACTORY_REPO`, 받는 곳은 기본값 없음), 원본 이슈 번호를 단 주석은 번호를 떼고 내용만 남겼다.
