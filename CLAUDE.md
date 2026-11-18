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

PR 병합은 `scripts/pr-merge.sh <PR>` 로만 한다 — 필수 검사(ci.yml backend·web·agent·exam-proxy-route·factory) 등록·초록을 확인한 뒤 squash 병합한다. `gh pr merge`·`gh api …/merge` 직접 호출은 `.claude/hooks/block-direct-merge.py` 가 막는다.
