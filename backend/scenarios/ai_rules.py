"""workstation 의 AI(Claude Code·Codex)에게 줄 규칙 전문.

공통 규칙(서버 상수) + 시나리오 할 일(설명) + 검사 이름·힌트(제약 표시) + 시나리오의 `ai_rules`.
검사 명령은 넣지 않는다 — AI 가 검사를 흉내 내 통과만 맞추지 않게.
"""

from __future__ import annotations

from .loader import Scenario

COMMON_RULES = """\
# 이 환경의 규칙

- `aws` 명령은 Floci(AWS 에뮬레이터)를 가리킨다. 엔드포인트는 이미 설정되어 있다.
- `kubectl` 은 이 환경의 kind 클러스터를 가리킨다.
- 호스트와 docker, 다른 컨테이너에는 접근하지 않는다. 이 셸의 도구(aws·kubectl·terraform)만 쓴다.
- 시나리오의 제약을 우회하지 않는다. 제약으로 적힌 것은 지우고 다시 만들기, 전부 열기 같은 방법으로 통과시키지 않는다.
- 작업 폴더는 `/work` 다.
- EC2 인스턴스 안에서 80 포트는 쓸 수 없다. 8080 등 다른 포트를 쓴다.
- 채점은 대시보드가 한다. 답을 추측하지 말고 실제 상태를 확인한다.
"""


def build_ai_rules(s: Scenario) -> str:
    parts = [COMMON_RULES.rstrip(), f"# 할 일\n\n{s.description.strip()}"]
    todo = [c for c in s.checks if not c.constraint]
    keep = [c for c in s.checks if c.constraint]

    def line(c) -> str:
        return f"- {c.name}" + (f" — {c.hint}" if c.hint else "")

    parts.append("## 해야 할 것\n\n" + "\n".join(line(c) for c in todo) if todo else "")
    if keep:
        parts.append("## 지켜야 할 것\n\n" + "\n".join(line(c) for c in keep))
    if s.ai_rules.strip():
        parts.append("# 이 시나리오의 추가 규칙\n\n" + s.ai_rules.strip())
    return "\n\n".join(p for p in parts if p) + "\n"
