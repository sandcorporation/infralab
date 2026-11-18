#!/usr/bin/env bash
# Tests of .github/factory/app-push.sh (#172): push only with the App token, and only its header.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../app-push.sh"

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  g init -q --bare "$tmp/origin.git"
  g init -q -b main "$tmp/repo"
  (cd "$tmp/repo" && echo a > a && g add a && g commit -q -m a && g remote add origin "$tmp/origin.git")
  # what actions/checkout leaves behind
  git -C "$tmp/repo" config http.https://github.com/.extraheader "AUTHORIZATION: basic Z2l0aHViLXRva2Vu"
}
remote_head() { git -C "$tmp/origin.git" rev-parse -q --verify refs/heads/main 2> /dev/null || echo none; }

setup "no App token: nothing is pushed"
(cd "$tmp/repo" && env -u FACTORY_APP_TOKEN bash "$script" -q origin main) > /dev/null 2>&1
eq "exit" 1 $?
eq "remote" none "$(remote_head)"

setup "App token: pushed"
(cd "$tmp/repo" && FACTORY_APP_TOKEN=app-token bash "$script" -q origin main) > /dev/null 2>&1
eq "exit" 0 $?
eq "remote" "$(git -C "$tmp/repo" rev-parse HEAD)" "$(remote_head)"

# The push sees exactly one extra header, the App's: the checkout's GITHUB_TOKEN header is reset (git's
# http.c drops the headers collected so far on an empty http.extraHeader value).
setup "only the App header goes out"
real=$(command -v git)
mkdir -p "$tmp/bin"
# a git that, asked to push, prints the extra headers the push would send instead
printf '#!/usr/bin/env bash\nargs=()\nfor a in "$@"; do [ "$a" = push ] && break; args+=("$a"); done\nexec %s "${args[@]}" config --get-all http.https://github.com/.extraheader\n' "$real" > "$tmp/bin/git"
chmod +x "$tmp/bin/git"
headers=$(cd "$tmp/repo" && PATH="$tmp/bin:$PATH" FACTORY_APP_TOKEN=app-token bash "$script" origin main 2>&1 \
  | awk 'NF == 0 { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }')
eq "headers" "AUTHORIZATION: basic $(printf 'x-access-token:app-token' | base64 | tr -d '\n')" "$headers"

echo "app-push.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
