#!/usr/bin/env bash
# Tests of .github/factory/acceptance-probe.sh (#212) with fake runners (tests/fake/probe) that replay
# real pytest-plugin, vitest JSON and `go test -json` output.
set -u
here=$(cd "$(dirname "$0")" && pwd)
probe="$here/../acceptance-probe.sh"
fake="$here/fake/probe"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1: [$2] unexpectedly in [$3]" ;; *) ok ;; esac; }

export PROBE_PYTEST="$fake/pytest" PROBE_VITEST="$fake/vitest" PROBE_GOTEST="$fake/gotest"

# setup <name>: a repository whose main has an older spec file; the branch adds this spec's files.
setup() {
  current=$1
  repo="$root/$RANDOM$RANDOM"
  export FAKE_SEEN="$repo.seen"
  mkdir -p "$repo/backend/tests" "$repo/web/src/spec" "$repo/agent" "$FAKE_SEEN"
  unset FAKE_PY FAKE_PY_NONE FAKE_VT FAKE_GO_BUILD
  cd "$repo" || exit 1
  git init -q -b main && git config user.email t@t && git config user.name t
  printf 'def test_old():\n    assert True\n' > backend/tests/test_spec_old.py
  git add -A && git commit -q -m base && git checkout -q -b factory/spec-1
}
# The branch's spec files (Decompose's commit; untracked ones stand for Odin's uncommitted fixes).
spec_backend() {
  cat > backend/tests/test_spec_zz_probe.py <<'EOF'
import pytest


@pytest.mark.skip(reason="#9")
def test_assert():
    assert 1 == 2
EOF
  printf 'from nowhere import thing  # noqa\n' > backend/tests/test_spec_zz_import.py
}
spec_web() {
  cat > web/src/spec/spec_zz_a.test.ts <<'EOF'
import { expect, it } from "vitest";
  it.skip("assert", () => { expect(1).toBe(2); }); // #9
EOF
  printf 'import { it } from "vitest";\n' > web/src/spec/spec_zz_b.test.ts
}
spec_agent() {
  cat > agent/spec_zz_a_test.go <<'EOF'
package main

func TestZzAssert(t *testing.T) {
	t.Skip("#9")
}

func TestZzPass(t *testing.T) {
	t.Skip("#9")
}

func TestZzStub(t *testing.T) {
	t.Skip("#9")
}

func TestZzNil(t *testing.T) {
	t.Skip("#9")
}
EOF
}
run() { out=$(bash "$probe" main 2>&1); rc=$?; }

setup "nothing to probe without changed acceptance files"
printf 'x\n' > README.md && git add -A && git commit -q -m readme
run
eq exit 0 "$rc"
has says "no acceptance files changed" "$out"
eq "no runner" "" "$(ls "$FAKE_SEEN")"

setup "backend: #194's ConstructorError, an import error and a broken fixture are errors"
spec_backend
git add backend/tests/test_spec_zz_probe.py && git commit -q -m spec
cp backend/tests/test_spec_zz_probe.py "$repo.before"
run
eq exit 1 "$rc"
has "#194" "acceptance-probe: error backend tests/test_spec_zz_probe.py::test_yaml: call: ConstructorError: could not determine a constructor for the tag '!reset'" "$out"
has "import" "acceptance-probe: error backend tests/test_spec_zz_import.py: collect: CollectError: ModuleNotFoundError" "$out"
has fixture "acceptance-probe: error backend tests/test_spec_zz_probe.py::test_fixture: setup: KeyError" "$out"
has "other NotImplementedError" "acceptance-probe: error backend tests/test_spec_zz_probe.py::test_other_not_implemented" "$out"
has assertion "acceptance-probe: fail backend tests/test_spec_zz_probe.py::test_assert: call: AssertionError" "$out"
has stub "acceptance-probe: fail backend tests/test_spec_zz_probe.py::test_stub: call: NotImplementedError: #9" "$out"
has "pytest.fail" "acceptance-probe: fail backend tests/test_spec_zz_probe.py::test_fail_call" "$out"
has pass "acceptance-probe: pass backend tests/test_spec_zz_probe.py::test_pass" "$out"
has count "acceptance-probe: 4 error(s)" "$out"
has "both files, untracked too" "tests/test_spec_zz_import.py" "$(cat "$FAKE_SEEN/pytest.args")"
has "the plugin" "-p probe_pytest" "$(cat "$FAKE_SEEN/pytest.args")"
lacks "older spec untouched" "test_spec_old.py" "$(cat "$FAKE_SEEN/pytest.args")"
lacks "marker off while running" '@pytest.mark.skip' "$(cat "$FAKE_SEEN/pytest.files")"
has "test still there" 'def test_assert' "$(cat "$FAKE_SEEN/pytest.files")"
eq "file restored" same "$(cmp -s backend/tests/test_spec_zz_probe.py "$repo.before" && echo same)"
eq "tree clean but the untracked fix" '?? backend/tests/test_spec_zz_import.py' "$(git status --porcelain)"

setup "backend: assertions and stubs only pass the probe"
spec_backend
grep -v -e test_yaml -e test_fixture -e test_other -e CollectError "$fake/pytest.jsonl" > "$repo.good"
export FAKE_PY="$repo.good"
run
eq exit 0 "$rc"
lacks "no error" "acceptance-probe: error" "$out"
has summary "every acceptance test fails on an assertion or its stub, or passes" "$out"

setup "backend: a runner without a result is an error"
spec_backend
export FAKE_PY_NONE=1
run
eq exit 1 "$rc"
has "no result" "acceptance-probe: error backend (runner): the runner gave no result (exit 4)" "$out"

setup "web: a TypeError and a file that does not load are errors, assertions and stubs are not"
spec_web
run
eq exit 1 "$rc"
has typeerror "acceptance-probe: error web src/spec/spec_zz_a.test.ts > typeerr: TypeError" "$out"
has "load" "acceptance-probe: error web src/spec/spec_zz_b.test.ts: Failed to load url ../does-not-exist" "$out"
has assertion "acceptance-probe: fail web src/spec/spec_zz_a.test.ts > assert: AssertionError" "$out"
has stub "acceptance-probe: fail web src/spec/spec_zz_a.test.ts > stub: Error: #9" "$out"
has rejects "acceptance-probe: fail web src/spec/spec_zz_a.test.ts > rejects" "$out"
has "resolves on a stub" "acceptance-probe: fail web src/spec/spec_zz_a.test.ts > resolves-stub" "$out"
has pass "acceptance-probe: pass web src/spec/spec_zz_a.test.ts > pass" "$out"
has count "acceptance-probe: 2 error(s)" "$out"
has "switched on" '  it("assert", () => { expect(1).toBe(2); });' "$(cat "$FAKE_SEEN/vitest.files")"
lacks "no marker left" '// #9' "$(cat "$FAKE_SEEN/vitest.files")"
has restored 'it.skip("assert", () => { expect(1).toBe(2); }); // #9' "$(cat web/src/spec/spec_zz_a.test.ts)"

setup "web: only a rejection other than the stub is an error under .resolves"
spec_web
jq '.testResults |= map(select(.name | endswith("spec_zz_a.test.ts"))
      | .assertionResults |= map(select(.fullName != "typeerr")
        | if .fullName == "resolves-stub" then .failureMessages = ["Error: promise rejected \"TypeError: x\" instead of resolving"] else . end))' \
  "$fake/vitest.json" > "$repo.vt"
export FAKE_VT="$repo.vt"
run
eq exit 1 "$rc"
has "other rejection" "acceptance-probe: error web src/spec/spec_zz_a.test.ts > resolves-stub" "$out"
has count "acceptance-probe: 1 error(s)" "$out"

setup "agent: a panic other than the stub is an error, each test runs on its own"
spec_agent
run
eq exit 1 "$rc"
has nil "acceptance-probe: error agent TestZzNil: panic: assignment to entry in nil map" "$out"
has stub "acceptance-probe: fail agent TestZzStub: panic: #9" "$out"
has assertion "acceptance-probe: fail agent TestZzAssert" "$out"
has pass "acceptance-probe: pass agent TestZzPass" "$out"
eq "one run per test" "TestZzAssert TestZzPass TestZzStub TestZzNil" "$(tr '\n' ' ' < "$FAKE_SEEN/gotest.runs" | sed 's/ $//')"
has restored 't.Skip("#9")' "$(cat agent/spec_zz_a_test.go)"

setup "agent: a build failure is one error"
spec_agent
export FAKE_GO_BUILD=1
run
eq exit 1 "$rc"
has build "acceptance-probe: error agent (build): build failed: # infralab/agent [infralab/agent.test] ./spec_zz_b_test.go:6:2: undefined: undefinedThing" "$out"
has "once" "acceptance-probe: 1 error(s)" "$out"

current="factory-odin.yml runs the probe in both checks (#212)"
wf=$(cat "$here/../../workflows/factory-odin.yml")
# shellcheck disable=SC2016 # the workflow text itself
has "first check" 'bash .github/factory/acceptance-probe.sh origin/$BASE || rc=1; exit \$rc" \
            > .factory/check-command' "$wf"
eq "both checks run the command" 2 "$(grep -c 'bash .factory/check-command 2>&1 | tee .factory/check.log' <<< "$wf")"
has "the reason shows the errors" "grep -E '^acceptance-probe: [0-9]*.?error' .factory/check.log" "$wf"

echo "acceptance-probe.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
