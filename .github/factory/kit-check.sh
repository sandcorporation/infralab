#!/usr/bin/env bash
# Checks that this copy of the factory kit matches the canonical one byte for byte (#437).
#
#   kit-check.sh <canonical .github/factory directory>
#
# The kit is the list in kit.txt next to this script (blank lines and `#` lines are skipped; paths are
# relative to .github/factory). For each listed file it prints one line when the file differs, or is
# missing here or in the canonical directory, and exits 1 when there was any such line. Exits 0 when
# every listed file is the same, 2 on a usage error (no directory, or no kit.txt here).
# A repository that copies the kit gives its own values through the environment, never by editing a
# listed file (kit.txt names the variables).
set -u
usage() { echo 'usage: kit-check.sh <canonical .github/factory directory>' >&2; exit 2; }
[ $# -eq 1 ] || usage
canon=$1
[ -d "$canon" ] || { echo "kit-check: no directory [$canon]" >&2; usage; }
here=$(cd "$(dirname "$0")" && pwd)
list="$here/kit.txt"
[ -f "$list" ] || { echo "kit-check: no kit.txt in $here" >&2; exit 2; }

bad=0 n=0
while IFS= read -r f || [ -n "$f" ]; do
  f=${f%$'\r'}
  case "$f" in '' | '#'*) continue ;; esac
  n=$((n + 1))
  if [ ! -f "$here/$f" ]; then echo "missing here: $f"; bad=1
  elif [ ! -f "$canon/$f" ]; then echo "missing in the canonical kit: $f"; bad=1
  elif ! cmp -s "$here/$f" "$canon/$f"; then echo "differs: $f"; bad=1
  fi
done < "$list"
[ "$bad" -eq 0 ] && echo "kit-check: $n files match"
exit $bad
