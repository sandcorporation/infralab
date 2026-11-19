#!/usr/bin/env bash
# Tests of .github/factory/kit-check.sh (the factory kit is the same in every copy, #437) and of kit.txt.
set -u
here=$(cd "$(dirname "$0")" && pwd)
factory="$here/.."

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1: [$2] in [$3]" ;; *) ok ;; esac; }

kit() { grep -v '^#' "$factory/kit.txt" | tr -d '\r' | grep -v '^$'; }

# copy <dir>: a copy of every kit file under <dir>
copy() {
  local f
  for f in $(kit); do mkdir -p "$1/$(dirname "$f")"; cp "$factory/$f" "$1/$f"; done
}

current="kit.txt lists the hand-over kit and every listed file is here"
for f in hand-to-human.sh record-failure.sh acceptance-probe.sh bridge.sh merge-check.sh workflow-guard.sh \
         tests/hand-to-human.sh tests/record-failure.sh tests/acceptance-probe.sh tests/bridge.sh \
         tests/merge-check.sh tests/workflow-guard.sh kit-check.sh tests/kit-check.sh; do
  has "listed" "$f" "$(kit)"
done
for f in $(kit); do [ -f "$factory/$f" ] && ok || bad "listed but not here: $f"; done
lacks "names no other repository" "github.com/" "$(cat "$factory/kit.txt")"

current="the same kit matches"
canon="$root/canon"; copy "$canon"
out=$(bash "$factory/kit-check.sh" "$canon" 2>&1); eq exit 0 $?
has "count" "files match" "$out"

current="a changed file is named and exits 1"
canon="$root/changed"; copy "$canon"
echo "# changed" >> "$canon/bridge.sh"
out=$(bash "$factory/kit-check.sh" "$canon" 2>&1); eq exit 1 $?
eq "names it" "differs: bridge.sh" "$out"

current="a file missing in the canonical kit is named and exits 1"
canon="$root/missing"; copy "$canon"
mv "$canon/tests/fake/gh" "$canon/tests/fake/gh.gone"
out=$(bash "$factory/kit-check.sh" "$canon" 2>&1); eq exit 1 $?
eq "names it" "missing in the canonical kit: tests/fake/gh" "$out"

current="a file missing here is named and exits 1"
canon="$root/canon2"; copy "$canon"
mine="$root/mine"; copy "$mine"
mv "$mine/merge-check.sh" "$mine/merge-check.sh.gone"
out=$(bash "$mine/kit-check.sh" "$canon" 2>&1); eq exit 1 $?
eq "names it" "missing here: merge-check.sh" "$out"

current="every difference is listed"
canon="$root/many"; copy "$canon"
echo x >> "$canon/ledger.sh"; echo x >> "$canon/tests/bridge.sh"
out=$(bash "$factory/kit-check.sh" "$canon" 2>&1); eq exit 1 $?
eq "two lines" 2 "$(printf '%s\n' "$out" | grep -c '^differs: ')"

current="usage errors exit 2"
bash "$factory/kit-check.sh" > /dev/null 2>&1; eq "no argument" 2 $?
bash "$factory/kit-check.sh" "$root/nowhere" > /dev/null 2>&1; eq "no directory" 2 $?

echo "kit-check.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
