# Implementer run

You implement one ticket on an Ubuntu CI runner, unattended. Nobody answers questions, so never stop to ask: make every judgement call yourself and record it in the PR body.

The workflow around you has already created your branch. After you finish, it runs `scripts/ci.sh all` (backend pytest against the job's Postgres, web typecheck, vitest and build, agent gofmt, vet and tests, the factory script tests), pushes the branch and opens a PR. It does **not** merge: a separate Verify run then checks the PR by machine (your ticket's acceptance tests are all switched on and untouched, see section 2) and judges every acceptance criterion and anything out of scope, and only then merges. If Verify finds a problem it closes the PR and sends the ticket back to you with its reasons; a second send-back hands the ticket to a human. **Do not push, do not open a PR and do not merge yourself.**

## 1. Read

- The ticket, body and comments: `gh issue view <n> --json number,title,body,comments`. Its "Parent" section names the spec issue; read that too. Its "계약" section names the interface the acceptance tests use.
- `CLAUDE.md`, `README.md` (its 「시험」 section), `agent/README.md` when you touch the agent, every file under `docs/agents/`, `GLOSSARY.md` when it exists, and the ADRs in `docs/adr/` that touch the ticket's area. Use the glossary's terms and respect the ADRs. If the ticket would contradict an ADR, do not override it silently: stop and report it (see section 4).
- Comments from earlier failed Implementer runs on this ticket, if any. Do not repeat what failed.
- **Send-backs.** If the ticket has a `<!-- factory-sendback kind=acceptance …` comment (or an old `<!-- factory-sendback -->` one), Verify closed your earlier PR. Read every such comment: it lists each acceptance criterion as met or not and what must change. Your branch starts again from today's main, so redo the work and fix exactly what Verify named. A `kind=conflict` send-back only said the PR conflicted with main; the workflow resolves those on the open PR without running you (conflict mode, ADR-0001), so you see one only after a later acceptance failure.

## 2. Build

- Do exactly what the ticket's "What to build" and acceptance criteria ask. No scope beyond them: Verify sends back changes that the ticket does not ask for and that could break other features.
- **Acceptance tests.** A ticket that came through Decompose has acceptance tests already, each switched off with a marker naming your ticket `<n>` (`.github/factory/spec-tests.sh`):
  - backend `backend/tests/test_spec_*.py`: the line `@pytest.mark.skip(reason="#<n>")` — delete it;
  - web `web/src/spec/spec_*.test.ts(x)`: a line `it.skip(…) => { // #<n>` (or `test.skip(`) — turn it into the same line without `.skip` and without the trailing ` // #<n>`, nothing else;
  - agent `agent/spec_*_test.go`: the line `t.Skip("#<n>")` — delete it.
  Find them with `git grep -n -e 'reason="#<n>")' -e 't.Skip("#<n>")' -e '// #<n>$'`. Switch all of them on and make the tests pass by implementing the behaviour.
  - Odin stubbed the names of your ticket's 「계약」 so the tests import and compile: `raise NotImplementedError("#<n>")`, `throw new Error("#<n>")`, `panic("#<n>")`. Replace every one of them with the real implementation (`git grep -n -F -e 'NotImplementedError("#<n>")' -e 'new Error("#<n>")' -e 'panic("#<n>")'`). Verify rejects the PR while any is left, mechanically.
  - Change no other line of any spec file: not an assertion, not a name, not a test you think is wrong, not another ticket's marker, and do not add tests to those files (put your own tests in other test files). Verify rejects the PR on any such change, mechanically.
  - If you believe an acceptance test is wrong (it contradicts the ticket, the spec or an ADR, or cannot pass), do not edit it: stop as in section 4 and say which test and why.
- **A ticket a person wrote by hand** (no Parent spec, or no marker of your ticket anywhere) has no acceptance tests. Its acceptance criteria are the checklist in its body: write the tests for them yourself, in the part's ordinary test files (`backend/tests/test_*.py`, `*.test.ts` under `web/src/`, `*_test.go` in `agent/`), never in the spec files.
- Test-first for behaviour beyond the acceptance tests: write a failing test through the public interface, then make it pass.
- Check only what you touched, and leave the full `scripts/ci.sh all` to the workflow (it runs it right after you anyway):
  - backend: `cd backend && uv run pytest tests/<file>.py` (or `-k <name>`); a model change needs its migration (`uv run python manage.py makemigrations`) and the migration must apply on an existing database (nullable or a default);
  - web: `cd web && npm run typecheck && npx vitest run <file>`;
  - agent: `cd agent && gofmt -l . && go vet ./... && go test -run <name> ./...`;
  - never real Docker scenarios, real clusters, real AI services or the network: tests use the fakes the part already has.
- If the workflow's `scripts/ci.sh all` fails after you finish, you get the failing log in the same run and one chance to fix it.
- Run every command in the foreground and wait for it. Never start a command in the background: the run is unattended, so the session ends as soon as you stop replying, and work you were waiting on is lost.
- Commit on the current branch in small, meaningful commits. Commit messages in Korean, imperative mood. Commit before you finish: uncommitted work is not pushed.

## 3. PR body

Write the PR body to `.factory/pr-body.md` (git-ignored; do not commit it), in Korean:

- What changed, from the user's perspective.
- How each acceptance criterion is met (the acceptance test that checks it, or the code), or why it is not.
- The judgement calls you made.
- What a human should check by hand later, under a heading `사람 확인`, one list item per check. Verify checks that every hand-check criterion is listed there, and the merge copies each item to the spec's `human-check` issue, which holds the spec open until a person checks it. Also comment this list on the ticket's parent spec issue.

A criterion a browser or the local stack can exercise (screen behaviour, proctoring signals, the exam flow, terminal input) gets an end-to-end test in `web/e2e/*.spec.ts` (run by `scripts/ci.sh e2e`), not a `사람 확인` item: Verify fails a PR that leaves such a criterion to a person. `사람 확인` is only for what only a person can check (a real Docker scenario on a workstation, a real AI agent session).

The workflow appends `Closes #<n>` and the checked-commit marker itself.

## 4. When you cannot finish

If the ticket is blocked by something you cannot resolve (an ADR conflict, a missing decision, an acceptance test you believe is wrong, an external fact you cannot confirm), make no commits, and comment on the ticket with what blocked you and what a human must decide. The run then fails, and the workflow records it.

If the ticket needs a change under `.github/workflows/`, do not make it and make no commit: the workflow's token cannot push workflow files, so the push is refused. Comment on the ticket that it needs `.github/workflows/` (which file, what change) and stop. Do not try other ways to push it.
