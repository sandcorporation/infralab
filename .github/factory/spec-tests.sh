# Acceptance-test conventions of the factory in this repository (docs/adr/0001-software-factory.md
# "인수 시험"). Sourced by decompose.sh and verify.sh; not run on its own.
#
# Each acceptance test belongs to exactly one ticket #N and is switched off with one marker line:
#
#   backend  backend/tests/test_spec_<slug>_<group>.py   a line `@pytest.mark.skip(reason="#N")`
#                                                       right above the test function
#   web      web/src/spec/spec_<slug>_<group>.test.ts(x) the test opens with `it.skip(` (or `test.skip(`)
#                                                       and that line ends with `// #N`
#   agent    agent/spec_<slug>_<group>_test.go          the first line of the test is `t.Skip("#N")`
#
# Ticket #N's Implementer switches its tests on: it deletes the backend and agent marker lines, and on
# web turns `it.skip(… // #N` into `it(…` (only `.skip` and the trailing comment go). Odin's stubs for
# the names of ticket #N's contract are `raise NotImplementedError("#N")`, `throw new Error("#N")` and
# `panic("#N")`; the ticket replaces every one of them.

# git pathspecs of the acceptance-test files.
SPEC_PATHSPECS=('backend/tests/test_spec_*.py' 'web/src/spec/spec_*.test.ts' 'web/src/spec/spec_*.test.tsx' 'agent/spec_*_test.go')
# The same as one ERE over a repository-relative path.
SPEC_PATH_RE='^(backend/tests/test_spec_[^/]*\.py|web/src/spec/spec_[^/]*\.test\.tsx?|agent/spec_[^/]*_test\.go)$'

# Markers and stubs of ticket #N (fixed strings; the web marker is the ERE spec_web_marker_re).
spec_py_marker() { printf '@pytest.mark.skip(reason="#%s")' "$1"; }
spec_go_marker() { printf 't.Skip("#%s")' "$1"; }
spec_web_marker_re() { printf '^[[:space:]]*(it|test)\\.skip\\(.*// #%s[[:space:]]*$' "$1"; }
spec_py_stub() { printf 'raise NotImplementedError("#%s")' "$1"; }
spec_ts_stub() { printf 'throw new Error("#%s")' "$1"; }
spec_go_stub() { printf 'panic("#%s")' "$1"; }

# Any ticket's marker, for a trimmed line.
SPEC_ANY_PY_RE='^@pytest\.mark\.skip\(reason="#[0-9]+"\)$'
SPEC_ANY_GO_RE='^t\.Skip\("#[0-9]+"\)$'
SPEC_ANY_WEB_RE='^(it|test)\.skip\(.*// #[0-9]+$'

# spec_has_tests <root> <N>: whether the tree at <root> has an acceptance test of ticket #N.
spec_has_tests() {
  local root=$1 n=$2
  grep -rqF --include='test_spec_*.py' -- "$(spec_py_marker "$n")" "$root/backend/tests" 2> /dev/null && return 0
  grep -rqF --include='spec_*_test.go' -- "$(spec_go_marker "$n")" "$root/agent" 2> /dev/null && return 0
  grep -rqE --include='spec_*.test.ts' --include='spec_*.test.tsx' -- "$(spec_web_marker_re "$n")" \
    "$root/web/src/spec" 2> /dev/null && return 0
  return 1
}

# spec_web_enabled <line> <N>: the line a web marker line of ticket #N becomes once switched on
# (`.skip` after `it`/`test` and the trailing `// #N` removed, indentation kept).
spec_web_enabled() {
  printf '%s' "$1" | sed -E "s/^([[:space:]]*)(it|test)\\.skip\\(/\\1\\2(/; s/[[:space:]]*\\/\\/ #$2[[:space:]]*\$//"
}
