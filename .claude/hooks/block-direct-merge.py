#!/usr/bin/env python3
"""PreToolUse(Bash) 훅(#164): PR 을 직접 병합하는 명령을 막고 scripts/pr-merge.sh 로 보낸다.

막는 것: `gh pr merge …`, `gh api … /pulls/N/merge`, `gh api graphql … mergePullRequest`.
scripts/pr-merge.sh 는 안에서 gh pr merge 를 부르지만 그건 Bash 도구 명령 문자열에 나오지 않으니
`scripts/pr-merge.sh 12` 는 지나간다. 같은 명령 안에 직접 병합이 섞여 있으면(`… || gh pr merge 12`) 막는다.

공장(.github/factory/odin.sh·verify.sh)은 Actions 셸에서 gh api 로 병합하므로 이 훅을 거치지 않는다.
공장 에이전트(claude-code-action)는 병합하지 않으므로 걸릴 일이 없다.

종료 코드 2 + stderr = 막음(Claude Code 가 stderr 를 에이전트에 돌려준다). 입력을 못 읽으면 0(막지 않음).
"""

from __future__ import annotations

import json
import re
import sys

MESSAGE = "scripts/pr-merge.sh <PR> 로 병합하라 — 검사 초록 확인 뒤 병합한다 (직접 gh pr merge·gh api …/merge 금지, #164)"

# 명령 구분자(; & | 줄바꿈) 를 넘지 않는 한 덩어리 안에서 찾는다.
_SEG = r"[^;&|\n]*"
PATTERNS = (
    re.compile(r"\bgh\s+pr\s+merge\b"),
    re.compile(r"\bgh\s+api\b" + _SEG + r"/pulls/[^/\s'\"]+/merge\b"),
    re.compile(r"\bgh\s+api\b" + _SEG + r"\bmergePullRequest\b"),
)


def blocked(command: str) -> bool:
    return any(p.search(command) for p in PATTERNS)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        return 0
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if isinstance(command, str) and blocked(command):
        print(MESSAGE, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
