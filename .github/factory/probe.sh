#!/usr/bin/env bash
# infralab's acceptance probe: acceptance-probe.sh (facet kit, #238) with this repository's settings.
#
#   probe.sh [<base ref>]        (default origin/main)
#
# The kit's probe defaults to cargo; here the acceptance files are spec-tests.sh's (backend pytest,
# web vitest, agent go), and a test that already passes is printed and recorded only (PROBE_GREEN=pass),
# as the probe did before the kit (#212). A value already in the environment wins.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=spec-tests.sh
. "$here/spec-tests.sh"
export PROBE_RUNNERS=${PROBE_RUNNERS:-pytest,vitest,go}
export PROBE_FILES_RE=${PROBE_FILES_RE:-$SPEC_PATH_RE}
export PROBE_GREEN=${PROBE_GREEN:-pass}
export PROBE_LOG=${PROBE_LOG:-.factory/probe.log}
exec bash "$here/acceptance-probe.sh" "$@"
