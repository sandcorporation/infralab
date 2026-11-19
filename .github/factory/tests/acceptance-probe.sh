#!/usr/bin/env bash
# Tests of .github/factory/acceptance-probe.sh against a fake cargo (tests/fake/cargo), #414.
# Each case is a throwaway git repository whose spec branch adds an ignored acceptance test, and
# canned `cargo test` output for one reason the test is red.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../acceptance-probe.sh"
export PATH="$here/fake:$PATH"
root=$(mktemp -d)
trap 'rm -r "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$2" in *"$1"*) ok ;; *) bad "expected [$1] in: $2" ;; esac; }

g() { git -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false "$@" > /dev/null 2>&1; }

# setup <name>: a repository with main (a crate without spec tests) and the spec branch checked out
# with crates/foo/tests/spec_x.rs: test `adds` (#42) asserts on line 7 and unwraps on line 6.
setup() {
  current=$1
  repo="$root/$RANDOM$RANDOM"
  mkdir -p "$repo/crates/foo/tests" "$repo/crates/foo/src"
  cd "$repo" || exit 1
  printf '[package]\nname = "foo"\nversion = "0.1.0"\n\n[dependencies]\n' > crates/foo/Cargo.toml
  printf 'pub fn thing() -> Result<u32, String> {\n    Ok(1)\n}\n' > crates/foo/src/lib.rs
  g init -q -b main . && g add -A && g commit -q -m base
  g checkout -q -b spec
  write_spec
  g add -A && g commit -q -m spec
  export FAKE_CARGO_LOG="$repo/.cargo-calls" FAKE_CARGO_OUT="$repo/.cargo-out" FAKE_CARGO_EXIT=101
  export PROBE_LOG="$repo/.factory/probe.log"
  : > "$FAKE_CARGO_LOG"
}
write_spec() {
  mkdir -p crates/foo/tests
  cat > crates/foo/tests/spec_x.rs <<'RS'
use foo::thing;

#[test]
#[ignore = "#42"]
fn adds() {
    let v = thing().unwrap();
    assert_eq!(v, 3);
}

#[test]
fn already_merged_spec_test_is_not_probed() {}
RS
}
cargo_says() { printf '%s\n' "$@" > "$FAKE_CARGO_OUT"; }
probe() { out=$(bash "$script" main 2>&1); code=$?; }
failed_at() { # failed_at <location> <message>: cargo output of `adds` panicking there
  cargo_says '' 'running 1 test' 'test adds ... FAILED' '' 'failures:' '' '---- adds stdout ----' \
    "thread 'adds' panicked at $1:" "$2" 'note: run with `RUST_BACKTRACE=1`' '' 'failures:' '    adds' '' \
    'test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 1 filtered out'
}

setup "an assertion failure passes"
failed_at crates/foo/tests/spec_x.rs:7:5 'assertion `left == right` failed'
probe
eq exit 0 "$code"
has 'acceptance-probe ok crates/foo/tests/spec_x.rs::adds (#42): 단언 실패' "$out"
eq "cargo call" "test -p foo --test spec_x -- --ignored adds" "$(cat "$FAKE_CARGO_LOG")"

setup "a custom assertion message is still an assertion (by its line)"
failed_at crates/foo/tests/spec_x.rs:7:5 'the sum must be three'
probe
eq exit 0 "$code"
has '단언 실패' "$out"

setup "a todo! stub passes"
failed_at crates/foo/src/lib.rs:2:5 'not yet implemented: #42'
probe
eq exit 0 "$code"
has 'acceptance-probe ok crates/foo/tests/spec_x.rs::adds (#42): 스텁' "$out"

setup "an unwrap panic fails"
failed_at crates/foo/tests/spec_x.rs:6:21 'called `Result::unwrap()` on an `Err` value: "no fixture"'
probe
eq exit 1 "$code"
has 'acceptance-probe FAILED crates/foo/tests/spec_x.rs::adds (#42): 단언·스텁이 아닌 panic' "$out"

setup "a panic in a library outside the tests fails"
failed_at crates/foo/src/lib.rs:2:5 'index out of bounds: the len is 0 but the index is 0'
probe
eq exit 1 "$code"
has 'FAILED' "$out"

setup "a compile error fails and shows the error"
cargo_says '   Compiling foo v0.1.0' 'error[E0425]: cannot find function `thing2` in crate `foo`' \
  ' --> crates/foo/tests/spec_x.rs:6:13' '' 'error: could not compile `foo` (test "spec_x") due to 1 previous error'
probe
eq exit 1 "$code"
has 'acceptance-probe FAILED crates/foo/tests/spec_x.rs::adds (#42): 컴파일 오류' "$out"
has 'error[E0425]: cannot find function' "$out"

setup "an already green test fails"
cargo_says '' 'running 1 test' 'test adds ... ok' '' 'test result: ok. 1 passed; 0 failed; 0 ignored'
FAKE_CARGO_EXIT=0
probe
eq exit 1 "$code"
has '이미 초록' "$out"

setup "a test cargo did not run fails"
cargo_says '' 'running 0 tests' '' 'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out'
FAKE_CARGO_EXIT=0
probe
eq exit 1 "$code"
has '시험을 찾지 못했다' "$out"

setup "no changed acceptance test runs nothing"
g checkout -q main
mkdir -p crates/foo/tests && printf '#[test]\nfn plain() {}\n' > crates/foo/tests/plain.rs && g add -A && g commit -q -m plain
g checkout -q -b other
printf '// docs\n' >> crates/foo/src/lib.rs && g add -A && g commit -q -m other
probe
eq exit 0 "$code"
has '바뀐 인수 시험 없음' "$out"
eq "cargo calls" "" "$(cat "$FAKE_CARGO_LOG")"

setup "an uncommitted fix (Odin's) is probed too"
g checkout -q main
g checkout -q -b uncommitted
write_spec
failed_at crates/foo/tests/spec_x.rs:7:5 'assertion `left == right` failed'
probe
eq exit 0 "$code"
has 'acceptance-probe ok crates/foo/tests/spec_x.rs::adds' "$out"


setup "an already green test passes with PROBE_GREEN=pass (recorded only)"
cargo_says '' 'running 1 test' 'test adds ... ok' '' 'test result: ok. 1 passed; 0 failed; 0 ignored'
FAKE_CARGO_EXIT=0
PROBE_GREEN=pass probe
eq exit 0 "$code"
has 'acceptance-probe ok crates/foo/tests/spec_x.rs::adds (#42): 이미 초록' "$out"

setup "the number of changed acceptance test files is printed"
failed_at crates/foo/tests/spec_x.rs:7:5 'assertion `left == right` failed'
probe
has 'acceptance-probe: 바뀐 인수 시험 파일 1개' "$out"

setup "a pattern that matches no file in the repository is a configuration error"
PROBE_FILES_RE='^nowhere/[^/]+\.rs$' probe
eq exit 2 "$code"
has 'PROBE_FILES_RE' "$out"
eq "cargo calls" "" "$(cat "$FAKE_CARGO_LOG")"

setup "an unknown runner is a configuration error"
PROBE_RUNNERS=cargo,mocha probe
eq exit 2 "$code"
has 'mocha' "$out"

setup "another runner without PROBE_FILES_RE is a configuration error"
PROBE_RUNNERS=cargo,pytest probe
eq exit 2 "$code"
has 'PROBE_FILES_RE' "$out"

setup "a bad PROBE_GREEN is a configuration error"
PROBE_GREEN=maybe probe
eq exit 2 "$code"

# Other runners (pytest, vitest, go): the spec branch lifts nothing by itself; the probe removes the
# skip markers for the run and puts the files back afterwards.
export PROBE_PYTEST="$here/fake/probe/pytest" PROBE_VITEST="$here/fake/probe/vitest" PROBE_GOTEST="$here/fake/probe/gotest"
multi_re='^(backend/tests/test_spec_[^/]*\.py|web/src/spec/spec_[^/]*\.test\.tsx?|agent/spec_[^/]*_test\.go)$'
# msetup <name>: main has older spec files of all three kinds; the spec branch is checked out.
msetup() {
  current=$1
  repo="$root/$RANDOM$RANDOM"
  mkdir -p "$repo/backend/tests" "$repo/web/src/spec" "$repo/agent"
  cd "$repo" || exit 1
  printf 'def test_old():\n    pass\n' > backend/tests/test_spec_old.py
  printf 'it("old", () => {})\n' > web/src/spec/spec_old.test.ts
  printf 'package agent\n\nfunc TestOld(t *testing.T) {}\n' > agent/spec_old_test.go
  g init -q -b main . && g add -A && g commit -q -m base
  g checkout -q -b spec
  export FAKE_SEEN="$repo.seen" FAKE_GO="$repo.go" PROBE_LOG="$repo.probe.log"
  export PROBE_RUNNERS=pytest,vitest,go PROBE_FILES_RE="$multi_re"
  mkdir -p "$FAKE_SEEN" "$FAKE_GO"
  unset FAKE_PY FAKE_PY_EXIT FAKE_VT PROBE_GREEN
}
commit() { g add -A && g commit -q -m spec; }
py_spec() {
  cat > backend/tests/test_spec_x.py <<'PY'
import pytest


@pytest.mark.skip(reason="#42")
def test_adds():
    assert 1 == 3
PY
}
py_says() { printf '%s\n' "$@" > "$repo.py.jsonl"; export FAKE_PY="$repo.py.jsonl"; }
row() { # row <test> <outcome> [<type> <message> [<when>]]
  printf '{"test":"tests/test_spec_x.py::%s","when":"%s","outcome":"%s","type":"%s","message":"%s"}' \
    "$1" "${5:-call}" "$2" "${3:-}" "${4:-}"
}

msetup "pytest: assertion and stub failures pass, other errors fail"
py_spec && commit
py_says "$(row test_adds failed AssertionError 'assert 1 == 3')" "$(row test_stub failed NotImplementedError '#42')" \
  "$(row test_key failed KeyError "'x'")" "$(row test_fixture failed FixtureError 'no db' setup)"
probe
eq exit 1 "$code"
has 'acceptance-probe: 바뀐 인수 시험 파일 1개' "$out"
has "acceptance-probe: fail backend tests/test_spec_x.py::test_adds: call: AssertionError: assert 1 == 3" "$out"
has "acceptance-probe: fail backend tests/test_spec_x.py::test_stub: call: NotImplementedError: #42" "$out"
has "acceptance-probe: error backend tests/test_spec_x.py::test_key: call: KeyError: 'x'" "$out"
has "acceptance-probe: error backend tests/test_spec_x.py::test_fixture: setup: FixtureError: no db" "$out"
has 'acceptance-probe: 2 error(s)' "$out"
eq "pytest ran in backend" "$repo/backend" "$(cat "$FAKE_SEEN/pytest.cwd")"
has '-p probe_pytest' "$(cat "$FAKE_SEEN/pytest.args")"
has 'tests/test_spec_x.py' "$(cat "$FAKE_SEEN/pytest.args")"
case "$(cat "$FAKE_SEEN/pytest.args")" in *test_spec_old*) bad "an unchanged spec file was run" ;; *) ok ;; esac
case "$(cat "$FAKE_SEEN/pytest.files")" in *'mark.skip(reason="#42")'*) bad "the skip marker was not lifted" ;; *) ok ;; esac
has 'mark.skip(reason="#42")' "$(cat backend/tests/test_spec_x.py)"
eq "working tree clean afterwards" "" "$(git status --porcelain)"

msetup "pytest: only assertion failures exit 0"
py_spec && commit
py_says "$(row test_adds failed AssertionError 'assert 1 == 3')" "$(row test_stub failed Failed 'not yet')"
probe
eq exit 0 "$code"
has 'acceptance-probe: every acceptance test fails on an assertion or its stub' "$out"

msetup "pytest: a passing test fails by default (PROBE_GREEN=fail)"
py_spec && commit
py_says "$(row test_adds failed AssertionError 'x')" "$(row test_old passed)"
probe
eq exit 1 "$code"
has 'acceptance-probe: pass backend tests/test_spec_x.py::test_old' "$out"
has 'acceptance-probe: 1 pass(es)' "$out"

msetup "pytest: a passing test is only recorded with PROBE_GREEN=pass"
py_spec && commit
py_says "$(row test_adds failed AssertionError 'x')" "$(row test_old passed)"
PROBE_GREEN=pass probe
eq exit 0 "$code"
has 'acceptance-probe: pass backend tests/test_spec_x.py::test_old' "$out"
has 'or passes' "$out"

msetup "pytest: a collection error fails"
py_spec && commit
py_says "$(row '' failed CollectError 'ImportError: no module' collect)"
probe
eq exit 1 "$code"
has 'acceptance-probe: error backend' "$out"
has 'collect: CollectError: ImportError: no module' "$out"

msetup "a runner that writes no result fails"
py_spec && commit
FAKE_PY_EXIT=4 probe
eq exit 1 "$code"
has 'acceptance-probe: error backend (runner): the runner gave no result (exit 4): fake pytest output' "$out"

# The real pytest with the real probe_pytest plugin (#492): the fake pytest above copies canned rows,
# so a plugin that never wrote the exception type went unnoticed. Skipped without pytest.
if python3 -m pytest --version > /dev/null 2>&1; then
  msetup "real pytest: an assertion and a ticket stub fail, a fixture error is an error"
  cat > backend/tests/test_spec_x.py <<'PY'
import pytest


@pytest.fixture
def db():
    raise RuntimeError("no db")


@pytest.mark.skip(reason="#42")
def test_adds():
    assert 1 == 3


@pytest.mark.skip(reason="#42")
def test_stub():
    raise NotImplementedError("#42")


@pytest.mark.skip(reason="#42")
def test_fixture(db):
    pass
PY
  commit
  PROBE_PYTEST="python3 -m pytest" probe
  eq exit 1 "$code"
  has "acceptance-probe: fail backend tests/test_spec_x.py::test_adds: call: AssertionError: assert 1 == 3" "$out"
  has "acceptance-probe: fail backend tests/test_spec_x.py::test_stub: call: NotImplementedError: #42" "$out"
  has "acceptance-probe: error backend tests/test_spec_x.py::test_fixture: setup: RuntimeError: no db" "$out"
  has 'acceptance-probe: 1 error(s)' "$out"
  eq "working tree clean afterwards" "" "$(git status --porcelain)"
else
  echo "  skip [real pytest]: python3 -m pytest가 없어 건너뜀"
fi

msetup "vitest: assertion and #N stubs pass, other errors fail"
cat > web/src/spec/spec_x.test.ts <<'TS'
import { it, expect } from "vitest"

it.skip("adds", () => { expect(1).toBe(3) }) // #42
test.skip("loads", async () => { await load() }) // #42
TS
commit
cat > "$repo.vt.json" <<'JSON'
{"testResults":[{"name":"@DIR@/src/spec/spec_x.test.ts","message":"","assertionResults":[
 {"fullName":"adds","status":"failed","failureMessages":["AssertionError: expected 1 to be 3\n    at x"]},
 {"fullName":"stub","status":"failed","failureMessages":["\nError: #42\n    at y"]},
 {"fullName":"loads","status":"failed","failureMessages":["TypeError: load is not a function"]},
 {"fullName":"old","status":"passed","failureMessages":[]}]}]}
JSON
export FAKE_VT="$repo.vt.json"
PROBE_GREEN=pass probe
eq exit 1 "$code"
has 'acceptance-probe: fail web src/spec/spec_x.test.ts > adds: AssertionError: expected 1 to be 3' "$out"
has 'acceptance-probe: fail web src/spec/spec_x.test.ts > stub: Error: #42' "$out"
has 'acceptance-probe: error web src/spec/spec_x.test.ts > loads: TypeError: load is not a function' "$out"
has 'acceptance-probe: pass web src/spec/spec_x.test.ts > old' "$out"
eq "vitest ran in web" "$repo/web" "$(cat "$FAKE_SEEN/vitest.cwd")"
has 'src/spec/spec_x.test.ts' "$(cat "$FAKE_SEEN/vitest.args")"
has 'it("adds", () => { expect(1).toBe(3) })' "$(cat "$FAKE_SEEN/vitest.files")"
has 'test("loads", async () => { await load() })' "$(cat "$FAKE_SEEN/vitest.files")"
has 'it.skip("adds"' "$(cat web/src/spec/spec_x.test.ts)"

msetup "go: one run per test; #N panics pass, other panics and build failures fail"
cat > agent/spec_x_test.go <<'GO'
package agent

func TestStub(t *testing.T) {
	t.Skip("#42")
	panic("#42")
}

func TestOther(t *testing.T) {
	t.Skip("#42")
	var m map[string]int
	m["a"] = 1
}
GO
commit
printf '%s\n' '{"Action":"output","Test":"TestStub","Output":"panic: #42 [recovered]\n"}' '{"Action":"fail","Test":"TestStub"}' > "$FAKE_GO/TestStub.jsonl"
printf '%s\n' '{"Action":"output","Test":"TestOther","Output":"panic: assignment to entry in nil map\n"}' '{"Action":"fail","Test":"TestOther"}' > "$FAKE_GO/TestOther.jsonl"
probe
eq exit 1 "$code"
has 'acceptance-probe: fail agent TestStub: panic: #42 [recovered]' "$out"
has 'acceptance-probe: error agent TestOther: panic: assignment to entry in nil map' "$out"
eq "go runs" "-run ^TestStub\$ .
-run ^TestOther\$ ." "$(cat "$FAKE_SEEN/gotest.args")"
case "$(cat "$FAKE_SEEN/gotest.files")" in *'t.Skip("#42")'*) bad "the skip was not lifted" ;; *) ok ;; esac

msetup "go: a build failure fails"
printf 'package agent\n\nfunc TestA(t *testing.T) {\n\tt.Skip("#42")\n}\n' > agent/spec_x_test.go
commit
printf '%s\n' '{"Action":"build-output","Output":"./x.go:3: undefined: Foo\n"}' '{"Action":"build-fail"}' > "$FAKE_GO/TestA.jsonl"
probe
eq exit 1 "$code"
has 'acceptance-probe: error agent (build): build failed: ./x.go:3: undefined: Foo' "$out"

msetup "a changed file whose runner is not switched on is a configuration error"
py_spec && commit
PROBE_RUNNERS=vitest,go probe
eq exit 2 "$code"
has 'backend/tests/test_spec_x.py' "$out"

msetup "nothing changed under the pattern runs nothing"
printf '# docs\n' > README.md && commit
probe
eq exit 0 "$code"
has '바뀐 인수 시험 없음' "$out"
has 'acceptance-probe: 바뀐 인수 시험 파일 0개' "$out"

cd "$here" || exit 1
echo "acceptance-probe: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
