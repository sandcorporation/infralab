#!/usr/bin/env bash
# Odin's acceptance probe (#414, #492): are the spec PR's acceptance tests red for the right reason?
#
#   acceptance-probe.sh [<base ref>]        (default origin/main)
#
# Picks the acceptance test files the spec PR adds or changes (against the merge base with <base ref>,
# working tree and untracked files included: Odin's fixes are not committed yet) and runs the tests in
# them once with their skip markers lifted. Which files are acceptance files:
#
#   PROBE_FILES_RE   an ERE on the repository-relative path (default ^crates/[^/]+/tests/[^/]+\.rs$)
#   PROBE_FILES_CMD  instead of the ERE: a shell command that reads candidate paths on stdin and prints
#                    the acceptance files among them
#
# A rule that matches no file in the whole repository is a configuration error (exit 2); a spec PR
# that changes none of them is normal. The number of changed acceptance files is always printed.
#
#   PROBE_RUNNERS    runners to use, comma or space separated (default cargo): cargo, pytest, vitest,
#                    go. A file is run by its extension (.rs cargo, .py pytest, .js/.jsx/.ts/.tsx
#                    vitest, _test.go go); a changed file whose runner is not listed is an error (2).
#                    Any runner other than cargo needs PROBE_FILES_RE or PROBE_FILES_CMD.
#   PROBE_GREEN      fail (default): a test that already passes fails the probe; pass: it is printed
#                    and recorded only.
#   PROBE_LOG        the runners' full output (default .factory/probe-cargo.log)
#   PROBE_PYTEST, PROBE_VITEST, PROBE_GOTEST   the commands (default `uv run pytest`,
#                    `npx vitest run`, `go test -json`)
#
# cargo: tests switched off with `#[ignore = "#<ticket>"]` run as
# `cargo test -p <crate> --test <file> -- --ignored <names>` and are sorted by why they are red:
#
#   assert   an assertion failed (`assert!`, `assert_eq!`, `assert_ne!`, `panic!` in the test file)  ok
#   stub     a ticket stub panicked (`todo!()`, `unimplemented!()`)                                ok
#   compile  the test file did not compile                                                          fails
#   missing  cargo ran but reported no result for the test                                           fails
#   green    the test already passes: it asserts nothing the ticket has to build                     fails
#   other    any other panic (`unwrap`/`expect` failed, fixture or I/O error, index out of range)   fails
#
# One line per test (`ok` or `FAILED`, so the workflow's log digest picks the failures up) and, for a
# compile error, the compiler's error lines. The panic location decides `assert` against `other`: the
# source line the panic points at (cargo prints it relative to the workspace root) is read from the
# checkout.
#
# The other runners run in the file's top directory (its "part", e.g. backend/, web/, agent/) with
# the markers removed for the run and the files put back afterwards: pytest drops the line
# `@pytest.mark.skip(reason="#<n>")` (and loads the probe_pytest plugin next to this script), vitest
# turns `it.skip(`/`test.skip(` into `it(`/`test(` on lines ending in `// #<n>`, go drops the line
# `t.Skip("#<n>")` and runs each `func Test...` of the file alone. Each test prints
# `acceptance-probe: <fail|error|pass> <part> <test>: <why>`: fail is an assertion or the ticket's
# stub (pytest AssertionError/Failed or NotImplementedError("#<n>"), vitest AssertionError or
# Error("#<n>"), go `panic: #<n>`), error is anything else (collection, fixture, build, other panic,
# a runner that writes no result).
#
# Exits 0 when every probed test is red for the right reason (or green with PROBE_GREEN=pass, or there
# are none), 1 otherwise, 2 on a usage or configuration error.
set -u
[ $# -le 1 ] || { echo 'usage: acceptance-probe.sh [<base ref>]' >&2; exit 2; }
base=${1:-origin/main}
here=$(cd "$(dirname "$0")" && pwd)
log=${PROBE_LOG:-.factory/probe-cargo.log}
green=${PROBE_GREEN:-fail}
conf() { echo "acceptance-probe: $*" >&2; exit 2; }
case "$green" in fail | pass) ;; *) conf "PROBE_GREEN must be fail or pass, not '$green'" ;; esac
runners=$(printf '%s' "${PROBE_RUNNERS:-cargo}" | tr ', \t' '\n\n\n' | sed '/^$/d' | sort -u)
for r in $runners; do
  case "$r" in cargo | pytest | vitest | go) ;; *) conf "unknown runner '$r' in PROBE_RUNNERS (cargo, pytest, vitest, go)" ;; esac
done
if [ -z "${PROBE_FILES_RE:-}${PROBE_FILES_CMD:-}" ] && [ "$runners" != cargo ]; then
  conf "PROBE_RUNNERS other than cargo need PROBE_FILES_RE (or PROBE_FILES_CMD) to say which files are acceptance tests"
fi
re=${PROBE_FILES_RE:-'^crates/[^/]+/tests/[^/]+\.rs$'}
# acceptance: the acceptance files among the paths on stdin.
acceptance() {
  if [ -n "${PROBE_FILES_CMD:-}" ]; then bash -c "$PROBE_FILES_CMD"; else grep -E "$re"; fi
}
rule=PROBE_FILES_RE; [ -n "${PROBE_FILES_CMD:-}" ] && rule=PROBE_FILES_CMD

mb=$(git merge-base "$base" HEAD 2>/dev/null) || { echo "acceptance-probe: no merge base with $base" >&2; exit 2; }
all=$( { git ls-files; git ls-files --others --exclude-standard; } | tr -d '\r' | acceptance | head -n 1)
[ -n "$all" ] || conf "$rule matches no file in the repository: check the rule"
files=$( { git diff --name-only --diff-filter=AM "$mb"
           git ls-files --others --exclude-standard; } \
         | tr -d '\r' | acceptance | sort -u)
mkdir -p "$(dirname "$log")"
: > "$log"
for f in $files; do
  case "$f" in
    *.rs) r=cargo ;; *.py) r=pytest ;; *_test.go) r=go ;; *.js | *.jsx | *.ts | *.tsx) r=vitest ;;
    *) conf "no runner for $f (cargo .rs, pytest .py, vitest .js/.jsx/.ts/.tsx, go _test.go)" ;;
  esac
  printf '%s\n' $runners | grep -qx "$r" || conf "$f needs the $r runner, which PROBE_RUNNERS does not list"
done
echo "acceptance-probe: 바뀐 인수 시험 파일 $(printf '%s' "$files" | grep -c .)개"

# probed <file>: "<name> <ticket>" for each test switched off with #[ignore = "#<ticket>"].
probed() {
  tr -d '\r' < "$1" | awk '
    match($0, /#\[ignore *= *"#[0-9]+/) { t = substr($0, RSTART, RLENGTH); sub(/.*#/, "", t); pending = t; next }
    pending != "" && match($0, /fn +[A-Za-z0-9_]+/) {
      n = substr($0, RSTART, RLENGTH); sub(/fn +/, "", n); print n, pending; pending = ""
    }'
}

# results <cargo output>: "<name>\t<status>\t<location>\t<message>" per test cargo reported, where
# status is ok/FAILED/ignored and location/message are the panic's (FAILED only).
results() {
  tr -d '\r' < "$1" | awk '
    function short(n) { sub(/.*::/, "", n); return n }
    /^test .* \.\.\. (ok|FAILED|ignored)/ {
      n = $2; s = $NF; status[short(n)] = s; order[++k] = short(n); next
    }
    /^---- .* stdout ----$/ { cur = short($2); want = 0; next }
    cur != "" && /panicked at / {
      line = $0
      if (match(line, /panicked at .*:[0-9]+:[0-9]+:$/)) {          # Rust >= 1.73: message on the next line
        l = substr(line, RSTART + 12); sub(/:$/, "", l); loc[cur] = l; want = 1
      } else if (match(line, /panicked at .*, [^ ]+:[0-9]+:[0-9]+$/)) { # older: at '\''msg'\'', file:line:col
        l = line; sub(/.*, /, "", l); loc[cur] = l
        m = line; sub(/.*panicked at '\''/, "", m); sub(/'\'', [^ ]+$/, "", m); msg[cur] = m
      }
      next
    }
    want && cur != "" { msg[cur] = $0; want = 0; next }
    END { for (i = 1; i <= k; i++) { n = order[i]; printf "%s\t%s\t%s\t%s\n", n, status[n], loc[n], msg[n] } }'
}

# kind <location> <message>: assert, stub or other for a failed test.
kind() {
  case "$2" in
    'not yet implemented'* | 'not implemented'*) echo stub; return ;;
    'assertion failed'* | 'assertion `'*) echo assert; return ;;
  esac
  local file=${1%:*}; file=${file%:*}; file=${file//\\//}
  local line=${1%:*}; line=${line##*:}
  case "$file" in crates/*/tests/*) ;; *) echo other; return ;; esac
  case "$line" in '' | *[!0-9]*) echo other; return ;; esac
  local src
  src=$(sed -n "${line}p" "$file" 2>/dev/null | tr -d '\r')
  case "$src" in
    *'.unwrap('* | *'.expect('* | *'.unwrap_err('* | *'.expect_err('*) echo other ;;
    *'assert!('* | *'assert_eq!('* | *'assert_ne!('* | *'assert_matches!('* | *'panic!('* | *'unreachable!('*) echo assert ;;
    *) echo other ;;
  esac
}

total=0 bad=0
report() { # report <ok|FAILED> <file> <name> <ticket> <why>
  total=$((total + 1))
  [ "$1" = ok ] || bad=$((bad + 1))
  printf 'acceptance-probe %s %s::%s (#%s): %s\n' "$1" "$2" "$3" "$4" "$5"
}

for f in $(printf '%s\n' $files | grep -E '\.rs$'); do
  list=$(probed "$f")
  [ -n "$list" ] || continue
  dir=${f#crates/}; dir=${dir%%/*}
  pkg=$(tr -d '\r' < "crates/$dir/Cargo.toml" | awk -F'"' '/^\[package\]/ { p = 1; next } /^\[/ { p = 0 } p && /^name *=/ { print $2; exit }')
  stem=$(basename "$f" .rs)
  names=$(printf '%s\n' "$list" | awk '{ print $1 }')
  out=$(mktemp)
  # shellcheck disable=SC2086 # one filter per test name
  cargo test -p "$pkg" --test "$stem" -- --ignored $names > "$out" 2>&1
  { echo "=== cargo test -p $pkg --test $stem -- --ignored $(echo $names)"; cat "$out"; } >> "$log"
  if ! grep -qE '^test .* \.\.\. (ok|FAILED|ignored)|^running [0-9]+ tests?' "$out" \
     && grep -qE '^error(\[E[0-9]+\])?:' "$out"; then
    while read -r name ticket; do report FAILED "$f" "$name" "$ticket" "컴파일 오류"; done <<< "$list"
    tr -d '\r' < "$out" | grep -E -A4 '^error(\[E[0-9]+\])?:' | head -n 40
    rm -f "$out"
    continue
  fi
  res=$(mktemp)
  results "$out" > "$res"
  while read -r name ticket; do
    row=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$res")
    status=$(printf '%s' "$row" | cut -f2)
    case "$status" in
      ok)
        if [ "$green" = pass ]; then report ok "$f" "$name" "$ticket" "이미 초록(PROBE_GREEN=pass라 기록만 한다)"
        else report FAILED "$f" "$name" "$ticket" "이미 초록(구현 없이 통과한다)"; fi ;;
      ignored) report FAILED "$f" "$name" "$ticket" "--ignored로도 돌지 않았다(다른 ignore가 붙었나)" ;;
      FAILED)
        loc=$(printf '%s' "$row" | cut -f3) msg=$(printf '%s' "$row" | cut -f4)
        case "$(kind "$loc" "$msg")" in
          assert) report ok "$f" "$name" "$ticket" "단언 실패($loc)" ;;
          stub) report ok "$f" "$name" "$ticket" "스텁($msg)" ;;
          *) report FAILED "$f" "$name" "$ticket" "단언·스텁이 아닌 panic($loc: $msg)" ;;
        esac ;;
      *) report FAILED "$f" "$name" "$ticket" "시험을 찾지 못했다(cargo가 결과를 내지 않음)" ;;
    esac
  done <<< "$list"
  rm -f "$out" "$res"
done

# The other runners. Each run writes "<verdict>\t<part>\t<test>\t<why>" rows to $rows.
tmp=$(mktemp -d)
rows="$tmp/rows"
: > "$rows"
n=0
restore() {
  local i=0 f
  for f in $lifted; do i=$((i + 1)); cp "$tmp/backup/$i" "$f"; done
  rm -r "$tmp"
}
lifted=
trap restore EXIT
mkdir -p "$tmp/backup"
# lift <file> <sed script>: back the file up and take its skip markers off for the run.
lift() {
  n=$((n + 1)); cp "$1" "$tmp/backup/$n"; lifted="$lifted $1"
  sed -E -i "$2" "$1"
}
# no_result <part> <exit> <output file>: the runner wrote nothing to judge.
no_result() {
  printf 'error\t%s\t(runner)\tthe runner gave no result (exit %s): %s\n' "$1" "$2" \
    "$(tr -d '\r' < "$3" | tail -n 5 | tr '\n\t' '  ' | sed 's/ *$//' | cut -c1-400)" >> "$rows"
}
# rel <part>: the files of that part, relative to it.
rel() { printf '%s\n' $files | grep -E "$2" | grep "^$1/" | sed "s#^$1/##"; }
parts() { printf '%s\n' $files | grep -E "$1" | cut -d/ -f1 | sort -u; }
# strip_root <part>: make the test column of vitest rows relative to the part directory (vitest
# reports absolute paths; on Windows they may start with a drive letter).
strip_root() {
  local unix win
  unix="$(cd "$1" && pwd)/" win="$(cd "$1" && { pwd -W 2>/dev/null || pwd; })/"
  awk -F'\t' -v OFS='\t' -v u="$unix" -v w="$win" '{
    if (index($3, u) == 1) $3 = substr($3, length(u) + 1)
    else if (tolower(substr($3, 1, length(w))) == tolower(w)) $3 = substr($3, length(w) + 1)
    print }'
}

for part in $(parts '\.py$'); do
  py=$(rel "$part" '\.py$')
  for f in $py; do lift "$part/$f" '/^[[:space:]]*@pytest\.mark\.skip\(reason="#[0-9]+"\)[[:space:]]*$/d'; done
  : > "$tmp/py.jsonl"
  # shellcheck disable=SC2086 # PROBE_PYTEST is a command line; one argument per file
  (cd "$part" && PROBE_OUT="$tmp/py.jsonl" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" \
     ${PROBE_PYTEST:-uv run pytest} -p probe_pytest -p no:cacheprovider -q --continue-on-collection-errors $py) > "$tmp/out" 2>&1
  code=$?
  { echo "=== pytest ($part) $(echo $py)"; cat "$tmp/out"; } >> "$log"
  if [ ! -s "$tmp/py.jsonl" ]; then no_result "$part" "$code" "$tmp/out"; continue; fi
  tr -d '\r' < "$tmp/py.jsonl" | jq -r --arg part "$part" '
    def one: gsub("[\t\n\r]+"; " ") | .[0:400];
    (if (.test // "") == "" then "(\(.when))" else .test end) as $t
    | if .outcome == "passed" then ["pass", $part, $t, ""]
      elif .when == "call" and (.type == "AssertionError" or .type == "Failed"
             or (.type == "NotImplementedError" and ((.message // "") | test("^#[0-9]+$"))))
      then ["fail", $part, $t, "\(.when): \(.type): \(.message // "")" | one]
      else ["error", $part, $t, "\(.when): \(.type // .outcome): \(.message // "")" | one] end
    | @tsv' >> "$rows"
done

for part in $(parts '\.(js|jsx|ts|tsx)$'); do
  web=$(rel "$part" '\.(js|jsx|ts|tsx)$')
  for f in $web; do lift "$part/$f" '/\/\/ #[0-9]+[[:space:]]*$/ { s/(^|[^A-Za-z0-9_.])(it|test)\.skip\(/\1\2(/; s/[[:space:]]*\/\/ #[0-9]+[[:space:]]*$// }'; done
  rm -f "$tmp/vt.json"
  # shellcheck disable=SC2086
  (cd "$part" && ${PROBE_VITEST:-npx vitest run} $web --reporter=json --outputFile="$tmp/vt.json") > "$tmp/out" 2>&1
  code=$?
  { echo "=== vitest ($part) $(echo $web)"; cat "$tmp/out"; } >> "$log"
  if [ ! -s "$tmp/vt.json" ]; then no_result "$part" "$code" "$tmp/out"; continue; fi
  tr -d '\r' < "$tmp/vt.json" | jq -r --arg part "$part" '
    def one: gsub("[\t\n\r]+"; " ") | .[0:400];
    .testResults[] | (.name | gsub("\\\\"; "/")) as $file
    | if (.message // "") != "" then ["error", $part, $file, .message | one]
      else .assertionResults[] | select(.status == "passed" or .status == "failed")
        | "\($file) > \(.fullName)" as $t
        | if .status == "passed" then ["pass", $part, $t, ""]
          else ((.failureMessages[0] // "") | split("\n") | map(select(test("\\S"))) | .[0] // "" | sub("^\\s+"; "")) as $why
            | if ($why | test("^AssertionError\\b|^Error: #[0-9]+$|^Error: promise resolved .* instead of rejecting|^Error: promise rejected \"Error: #[0-9]+\" instead of resolving|^Error: expected (number of assertions|at least one assertion)"))
              then ["fail", $part, $t, $why | one] else ["error", $part, $t, $why | one] end
          end
      end
    | @tsv' | strip_root "$part" >> "$rows"
done

for part in $(parts '_test\.go$'); do
  gof=$(rel "$part" '_test\.go$')
  tests=$(for f in $gof; do tr -d '\r' < "$part/$f" | sed -nE 's/^func (Test[A-Za-z0-9_]*)\(.*/\1/p'; done)
  for f in $gof; do lift "$part/$f" '/^[[:space:]]*t\.Skip\("#[0-9]+"\)[[:space:]]*$/d'; done
  for t in $tests; do
    # shellcheck disable=SC2086
    (cd "$part" && ${PROBE_GOTEST:-go test -json} -run "^$t\$" .) > "$tmp/go.jsonl" 2>&1
    code=$?
    { echo "=== go test ($part) -run ^$t\$"; cat "$tmp/go.jsonl"; } >> "$log"
    grep '^{' "$tmp/go.jsonl" | tr -d '\r' > "$tmp/go.json"
    before=$(wc -l < "$rows")
    [ -s "$tmp/go.json" ] && jq -rs --arg part "$part" --arg t "$t" '
      def strip: sub("\n$"; "");
      def one: gsub("[\t\n\r]+"; " ") | .[0:400];
      if any(.[]; .Action == "build-fail" or ((.FailedBuild // "") != "") or ((.Output // "") | test("\\[build failed\\]")))
      then ["error", $part, "(build)", "build failed: " + ([.[] | select(.Action == "build-output") | .Output | strip] | .[0:3] | join(" ")) | one]
      else
        [.[] | select(.Test == $t)] as $mine
        | ([$mine[] | select(.Action == "pass" or .Action == "fail") | .Action] | last // "") as $end
        | [$mine[] | select(.Action == "output") | .Output | strip | sub("^\\s+"; "")] as $out
        | [$out[] | select(test("^panic: "))] as $panics
        | if $end == "pass" then ["pass", $part, $t, ""]
          elif $end == "fail" then
            ([$panics[] | select(test("^panic: #[0-9]+( \\[[^\\]]*\\])?$") | not)] | .[0]) as $other
            | if $other != null then ["error", $part, $t, $other | one]
              else ["fail", $part, $t, ($panics[0] // ([$out[] | select(test("^(---|===)") | not)] | .[0]) // "") | one] end
          elif any(.[]; .Action == "fail") then
            ["error", $part, "(package)", [.[] | select(.Output != null) | .Output | strip] | .[-3:] | join(" ") | one]
          else empty end
      end
      | @tsv' < "$tmp/go.json" >> "$rows"
    [ "$(wc -l < "$rows")" -gt "$before" ] || no_result "$part" "$code" "$tmp/go.jsonl"
  done
done

errors=0 passed=0 others=0
while IFS=$'\t' read -r verdict part test why; do
  [ -n "$verdict" ] || continue
  others=$((others + 1))
  case "$verdict" in error) errors=$((errors + 1)) ;; pass) passed=$((passed + 1)) ;; esac
  printf 'acceptance-probe: %s %s %s%s\n' "$verdict" "$part" "$test" "${why:+: $why}"
done < <(awk -F'\t' '!seen[$0]++' "$rows")

if [ "$total" -eq 0 ] && [ "$others" -eq 0 ]; then
  echo "acceptance-probe: 바뀐 인수 시험 없음"
  exit 0
fi
status=0
if [ "$total" -gt 0 ]; then
  echo "acceptance-probe: $total개 중 $bad개 실패"
  [ "$bad" -eq 0 ] || status=1
fi
if [ "$others" -gt 0 ]; then
  if [ "$errors" -gt 0 ]; then
    echo "acceptance-probe: $errors error(s): these acceptance tests fail on an error of their own, not on the missing behaviour"
    status=1
  fi
  if [ "$green" = fail ] && [ "$passed" -gt 0 ]; then
    echo "acceptance-probe: $passed pass(es): these acceptance tests already pass without the ticket (PROBE_GREEN=pass only records them)"
    status=1
  fi
  if [ "$errors" -eq 0 ] && { [ "$green" = pass ] || [ "$passed" -eq 0 ]; }; then
    if [ "$green" = pass ]; then echo "acceptance-probe: every acceptance test fails on an assertion or its stub, or passes"
    else echo "acceptance-probe: every acceptance test fails on an assertion or its stub"; fi
  fi
fi
exit "$status"
