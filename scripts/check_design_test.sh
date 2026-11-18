#!/usr/bin/env bash
# scripts/check_design.mjs 시험(#135): 가짜 저장소를 만들어 실패·통과를 본다.
set -euo pipefail
cd "$(dirname "$0")/.."
check="$PWD/scripts/check_design.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# 가짜 저장소: 의존성 있는 package.json, 토큰만 쓰는 CSS, 주석 속 이슈 번호(#122).
mk() {
  local d="$tmp/$1"
  mkdir -p "$d/web/src" "$d/scripts"
  printf '{"dependencies":{"sandcorp-design":"github:sandcorporation/sandcorp-design#v0.8.0"}}\n' >"$d/web/package.json"
  printf '/* #fff 주석은 본다 안 본다 */\n.a { color: var(--color-ink); }\n' >"$d/web/src/ok.css"
  printf '// 고친 것(#122)\nexport const url = "https://example.com/#top";\n' >"$d/web/src/ok.ts"
  : >"$d/scripts/design-allowlist.txt"
  echo "$d"
}

expect() { # expect <ok|fail> <이름> <저장소> [출력에 있어야 할 글]
  local want="$1" name="$2" repo="$3" needle="${4:-}" out code
  set +e
  out="$(node "$check" "$repo" 2>&1)"
  code=$?
  set -e
  if { [ "$want" = ok ] && [ $code -ne 0 ]; } || { [ "$want" = fail ] && [ $code -eq 0 ]; }; then
    echo "FAIL $name: 종료 코드 $code (기대 $want)" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL $name: 출력에 「$needle」 없음" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  echo "ok   $name"
}

r="$(mk clean)"
expect ok "토큰만 쓰면 통과" "$r"

r="$(mk hex)"
printf '.b {\n  color: #1f2430;\n}\n' >"$r/web/src/bad.css"
expect fail "CSS hex 6자리 → 실패" "$r" "web/src/bad.css:2 색 리터럴 — 디자인 토큰(sandcorp-design)을 써라. 꼭 필요하면 scripts/design-allowlist.txt 에 까닭과 함께"

r="$(mk short)"
printf 'export const c = "#fff";\n' >"$r/web/src/bad.ts"
expect fail "TS hex 3자리 → 실패" "$r" "web/src/bad.ts:1 색 리터럴"

r="$(mk alpha)"
printf 'export const T = () => <div style={{ color: "#11223344" }} />;\n' >"$r/web/src/Bad.tsx"
expect fail "TSX hex 8자리 → 실패" "$r" "web/src/Bad.tsx:1 색 리터럴"

r="$(mk rgb)"
printf '.c { background: rgba(0, 0, 0, 0.1); }\n.d { color: hsl(10 20%% 30%%); }\n' >"$r/web/src/fn.css"
expect fail "rgba()·hsl() → 실패" "$r" "web/src/fn.css:2 색 리터럴"

r="$(mk allow-line)"
printf '.b {\n  color: #1f2430;\n}\n' >"$r/web/src/bad.css"
echo "web/src/bad.css:2 — 시험용 예외" >"$r/scripts/design-allowlist.txt"
expect ok "허용 목록(파일:줄) → 통과" "$r"

r="$(mk allow-file)"
printf 'export const c = "#fff";\n' >"$r/web/src/bad.ts"
printf '# 주석\nweb/src/bad.ts — 시험용 예외\n' >"$r/scripts/design-allowlist.txt"
expect ok "허용 목록(파일) → 통과" "$r"

r="$(mk allow-noreason)"
printf 'export const c = "#fff";\n' >"$r/web/src/bad.ts"
echo "web/src/bad.ts" >"$r/scripts/design-allowlist.txt"
expect fail "까닭 없는 허용 목록 → 실패" "$r" "design-allowlist.txt:1 형식"

r="$(mk nodep)"
printf '{"dependencies":{"react":"^18.3.1"}}\n' >"$r/web/package.json"
expect fail "sandcorp-design 의존성 없음 → 실패" "$r" "web/package.json 에 sandcorp-design 의존성이 없다 — cd web && npm install"

r="$(mk unpinned)"
printf '{"dependencies":{"sandcorp-design":"github:sandcorporation/sandcorp-design"}}\n' >"$r/web/package.json"
expect fail "태그 고정 아님 → 실패" "$r" "태그 고정이 아니다"

exit $fail
