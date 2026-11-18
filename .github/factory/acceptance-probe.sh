#!/usr/bin/env bash
# Odin's acceptance probe (factory-odin.yml "Checks", odin.md §5, #212).
#
#   acceptance-probe.sh <base>
#
# Switches on every acceptance test in the spec files this branch adds or changes against <base>
# (committed or not: Odin's fixes are not committed yet), runs them once, puts the files back and
# sorts each result:
#
#   fail   the test failed the way a test of unbuilt behaviour should: an assertion
#          (pytest AssertionError / pytest.fail, vitest AssertionError or a failed .resolves/.rejects,
#          go t.Error/t.Fatal), or the ticket's stub (NotImplementedError("#N"), Error("#N"), panic("#N"))
#   pass   the test already passes before its ticket (noted, not an error)
#   error  anything else: a collection or import error, a file that does not load or build, an
#          exception of the test's own code (TypeError, yaml ConstructorError, ...), a panic, an error
#          in a fixture, setup or teardown. No implementation can turn such a test green: the
#          Implementer may not touch the test (#194 stopped three times on a ConstructorError).
#
# Exits 1 when any test is an error or a part gave no result, 0 otherwise; prints one line per test,
# `acceptance-probe: <fail|pass|error> <part> <test>[: why]`.
# The runners can be replaced (tests): PROBE_PYTEST (default `uv run pytest`, run in backend/),
# PROBE_VITEST (default `npx vitest run`, in web/), PROBE_GOTEST (default `go test -json`, in agent/).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=spec-tests.sh
. "$here/spec-tests.sh"
[ $# -eq 1 ] || { echo 'usage: acceptance-probe.sh <base>' >&2; exit 2; }
base=$1
root=$(git rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2
mb=$(git merge-base "$base" HEAD) || { echo "acceptance-probe: error: no merge base with $base" >&2; exit 2; }

mapfile -t files < <({ git diff --name-only --diff-filter=d "$mb"; git ls-files -o --exclude-standard; } \
  | sort -u | grep -E "$SPEC_PATH_RE" || true)
if [ ${#files[@]} -eq 0 ]; then
  echo "acceptance-probe: no acceptance files changed against $base"
  exit 0
fi

tmp=$(mktemp -d)
restore() {
  local i
  for i in "${!files[@]}"; do
    [ -f "$tmp/backup/$i" ] && cp -p "$tmp/backup/$i" "${files[$i]}"
  done
  rm -r "$tmp"
}
trap restore EXIT
mkdir -p "$tmp/backup"

py=() web=() go=() gotests=()
for i in "${!files[@]}"; do
  f=${files[$i]}
  cp -p "$f" "$tmp/backup/$i"
  case "$f" in
    backend/*)
      sed -E -i '/^[[:space:]]*@pytest\.mark\.skip\(reason="#[0-9]+"\)[[:space:]]*$/d' "$f"
      py+=("${f#backend/}") ;;
    web/*)
      sed -E -i '/^[[:space:]]*(it|test)\.skip\(.*\/\/ #[0-9]+[[:space:]]*$/{
        s/^([[:space:]]*)(it|test)\.skip\(/\1\2(/
        s/[[:space:]]*\/\/ #[0-9]+[[:space:]]*$//
      }' "$f"
      web+=("${f#web/}") ;;
    agent/*)
      sed -E -i '/^[[:space:]]*t\.Skip\("#[0-9]+"\)[[:space:]]*$/d' "$f"
      go+=("${f#agent/}")
      mapfile -t -O "${#gotests[@]}" gotests < <(sed -nE 's/^func (Test[A-Za-z0-9_]*)\(.*/\1/p' "$f") ;;
  esac
done

: > "$tmp/results"
# result <part> <verdict> <test> [why]
result() { printf '%s\t%s\t%s\t%s\n' "$2" "$1" "$3" "${4:-}" >> "$tmp/results"; }
# no_result <part> <exit> <log>: the runner wrote nothing to read.
no_result() {
  result "$1" error "(runner)" "the runner gave no result (exit $2): $(tail -n 5 "$3" | tr '\n' ' ' | cut -c1-400)"
}

if [ ${#py[@]} -gt 0 ]; then
  : > "$tmp/py.jsonl"
  (cd backend && PROBE_OUT="$tmp/py.jsonl" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" \
    ${PROBE_PYTEST:-uv run pytest} -p probe_pytest -p no:cacheprovider -q --continue-on-collection-errors "${py[@]}") > "$tmp/py.log" 2>&1
  rc=$?
  if [ ! -s "$tmp/py.jsonl" ]; then
    no_result backend "$rc" "$tmp/py.log"
  else
    jq -r '
      (if .outcome == "passed" then "pass"
       elif .when != "call" then "error"
       elif .type == "AssertionError" or .type == "Failed" then "fail"
       elif .type == "NotImplementedError" and (.message | test("^#[0-9]+$")) then "fail"
       else "error" end) as $v
      | [$v, "backend", .test,
         (if .outcome == "passed" then "" else "\(.when): \(.type): \(.message)" end
          | gsub("[\t\n]+"; " ") | .[0:400])] | @tsv' "$tmp/py.jsonl" | tr -d '\r' >> "$tmp/results"
  fi
fi

if [ ${#web[@]} -gt 0 ]; then
  (cd web && ${PROBE_VITEST:-npx vitest run} "${web[@]}" --reporter=json --outputFile="$tmp/vt.json") \
    > "$tmp/vt.log" 2>&1
  rc=$?
  if [ ! -s "$tmp/vt.json" ]; then
    no_result web "$rc" "$tmp/vt.log"
  else
    jq -r --arg root "$root/web/" '
      def firstline: split("\n") | map(select(test("\\S"))) | first // "";
      def ok: test("^AssertionError\\b")
        or test("^Error: #[0-9]+$")
        or test("^Error: promise resolved .* instead of rejecting")
        or test("^Error: promise rejected \"Error: #[0-9]+\" instead of resolving")
        or test("^Error: expected (number of assertions|at least one assertion)");
      .testResults[] | (.name | ltrimstr($root)) as $file
      | (if (.message // "") != "" then [["error", "web", $file, (.message | firstline)]] else [] end)
        + [.assertionResults[] | select(.status == "passed" or .status == "failed")
           | ((.failureMessages // [])[0] // "" | firstline) as $m
           | [(if .status == "passed" then "pass" elif ($m | ok) then "fail" else "error" end),
              "web", "\($file) > \(.fullName)", $m]]
      | .[] | map(gsub("[\t\n]+"; " ") | .[0:400]) | @tsv' "$tmp/vt.json" | tr -d '\r' >> "$tmp/results"
  fi
fi

if [ ${#go[@]} -gt 0 ]; then
  # One run per test: a panic (a stub's too) ends the test binary, so the tests after it would not run.
  : > "$tmp/go.rows"
  for t in "${gotests[@]}"; do
    (cd agent && ${PROBE_GOTEST:-go test -json} -run "^$t\$" .) > "$tmp/go.jsonl" 2> "$tmp/go.log"
    rc=$?
    if ! jq -e -s 'length > 0' "$tmp/go.jsonl" > /dev/null 2>&1; then
      no_result agent "$rc" "$tmp/go.log"
      continue
    fi
    jq -r -s '
      def stub: test("^panic: #[0-9]+( \\[[^]]*\\])?$");
      (map(select(.Action == "build-output") | .Output) | join("") | split("\n") | map(select(. != ""))) as $build
      | if any(.[]; .Action == "build-fail" or (.Action == "fail" and .Test == null and (.FailedBuild // "") != "")
              or (.Action == "output" and .Test == null and ((.Output // "") | test("\\[build failed\\]")))) then
          ["error", "agent", "(build)", ("build failed: " + ($build | .[0:3] | join(" ")))]
        else
          . as $all
          | ($all | map(select(.Test != null and (.Action == "pass" or .Action == "fail"))) | map(.Test) | unique) as $tests
          | ($tests[] as $t
              | ($all | map(select(.Test == $t and (.Action == "pass" or .Action == "fail"))) | last | .Action) as $end
              | ($all | map(select(.Test == $t and .Action == "output") | .Output // "" | rtrimstr("\n"))
                 | map(select(test("^panic: ")))) as $panics
              | if $end == "pass" then ["pass", "agent", $t, ""]
                elif ($panics | length) > 0 and ($panics | all(stub) | not) then
                  ["error", "agent", $t, ($panics | map(select(stub | not)) | first)]
                else ["fail", "agent", $t, ($panics | first // "")] end),
            (if any($all[]; .Action == "fail" and .Test == null)
                and ([$all[] | select(.Action == "fail" and .Test != null)] | length) == 0 then
               ["error", "agent", "(package)", ($all | map(select(.Action == "output") | .Output // "")
                 | join("") | split("\n") | map(select(test("\\S"))) | .[-3:] | join(" "))]
             else empty end)
        end
      | map(gsub("[\t\n]+"; " ") | .[0:400]) | @tsv' "$tmp/go.jsonl" | tr -d '\r' >> "$tmp/go.rows"
  done
  awk '!seen[$0]++' "$tmp/go.rows" >> "$tmp/results"
fi

errors=0
while IFS=$'\t' read -r verdict part test why; do
  [ "$verdict" = error ] && errors=$((errors + 1))
  if [ -n "$why" ]; then
    echo "acceptance-probe: $verdict $part $test: $why"
  else
    echo "acceptance-probe: $verdict $part $test"
  fi
done < "$tmp/results"
if [ "$errors" -gt 0 ]; then
  echo "acceptance-probe: $errors error(s): these acceptance tests fail on an error of their own, not on the missing behaviour (odin.md §5)"
  exit 1
fi
echo "acceptance-probe: every acceptance test fails on an assertion or its stub, or passes"
