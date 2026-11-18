# infralab

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `sandcorporation/infralab` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root plus `docs/adr/`. See `docs/agents/domain.md`.

### Software factory

`spec` 라벨 → Decompose → Odin → Implementer → Verify 가 GitHub Actions(`.github/workflows/factory-*.yml`, 스크립트 `.github/factory/`)에서 돈다. 인수 시험 규칙·켜는 순서·모델 배정은 `docs/adr/0001-software-factory.md`.

### 병합

PR 병합은 `scripts/pr-merge.sh <PR>` 로 한다 — 필수 검사(ci.yml backend·web·agent·exam-proxy-route·factory) 등록·초록을 기다린 뒤 squash 병합한다. 초록 전 병합은 main ruleset(필수 검사, 예외 없음)이 GitHub 에서 거절한다(#172). 공장도 App 토큰으로 이 스크립트를 써서 병합한다.
