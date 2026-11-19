#!/usr/bin/env bash
# Tests of .github/factory/probe.sh: infralab's settings reach acceptance-probe.sh (#238).
set -u
here=$(cd "$(dirname "$0")" && pwd)
passes=0 fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then passes=$((passes + 1)); else fails=$((fails + 1)); echo "FAIL: missing '$1' in: $2"; fi; }

tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
cp "$here/../probe.sh" "$here/../spec-tests.sh" "$tmp/"
cat > "$tmp/acceptance-probe.sh" <<'EOF'
echo "args=$*"
echo "runners=$PROBE_RUNNERS"
echo "re=$PROBE_FILES_RE"
echo "green=$PROBE_GREEN"
echo "log=$PROBE_LOG"
EOF

out=$(env -u PROBE_RUNNERS -u PROBE_FILES_RE -u PROBE_GREEN -u PROBE_LOG bash "$tmp/probe.sh" origin/dev)
has 'args=origin/dev' "$out"
has 'runners=pytest,vitest,go' "$out"
has 're=^(backend/tests/test_spec_[^/]*\.py|web/src/spec/spec_[^/]*\.test\.tsx?|agent/spec_[^/]*_test\.go)$' "$out"
has 'green=pass' "$out"
has 'log=.factory/probe.log' "$out"

# The re matches every kind of acceptance file and nothing else.
. "$tmp/spec-tests.sh"
for p in backend/tests/test_spec_a_b.py web/src/spec/spec_a_b.test.ts web/src/spec/spec_a_b.test.tsx agent/spec_a_b_test.go; do
  has "$p" "$(printf '%s\n' "$p" | grep -E "$SPEC_PATH_RE")"
done
has 'none' "$(printf 'backend/tests/test_x.py\nweb/src/x.test.ts\n' | grep -E "$SPEC_PATH_RE" || echo none)"

out=$(PROBE_GREEN=fail bash "$tmp/probe.sh")
has 'green=fail' "$out"

echo "probe: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
