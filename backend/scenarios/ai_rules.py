"""workstation 의 AI(Claude Code·Codex)에게 줄 규칙 전문.

공통 규칙(서버 상수) + 시나리오 할 일(설명) + 검사 이름·힌트(제약 표시) + 시나리오의 `ai_rules`.
검사 명령은 넣지 않는다 — AI 가 검사를 흉내 내 통과만 맞추지 않게.

도구 규칙은 시나리오가 요구하는 환경(requires)을 따른다: Floci 를 쓰는 시나리오만 「aws 는 Floci」를,
kind 를 쓰는 시나리오만 「kubectl 은 kind」를 적고, 둘 다 아닌 코드 프로젝트 시나리오는 빌드·테스트 도구를 허용 도구로 적는다.
"""

from __future__ import annotations

from .loader import Scenario


def _common_rules(s: Scenario) -> str:
    floci, kind = s.requires.floci, s.requires.kind is not None
    lines = ["# 이 환경의 규칙", ""]
    tools: list[str] = []
    if floci:
        lines.append("- `aws` 명령은 Floci(AWS 에뮬레이터)를 가리킨다. 엔드포인트는 이미 설정되어 있다.")
        tools += ["aws", "terraform"]
    if kind:
        lines.append("- `kubectl` 은 이 환경의 kind 클러스터를 가리킨다.")
        tools.append("kubectl")
    if floci or kind:
        lines.append(f"- 호스트와 docker, 다른 컨테이너에는 접근하지 않는다. 이 셸의 도구({'·'.join(tools)})만 쓴다.")
    else:
        lines.append(
            "- 호스트와 docker, 다른 컨테이너에는 접근하지 않는다. 이 셸의 도구만 쓴다 — "
            "프로젝트의 빌드·테스트 도구(npm, node, python3, pip, pytest, java, ./gradlew)와 git 은 쓴다."
        )
    lines.append("- 시나리오의 제약을 우회하지 않는다. 제약으로 적힌 것은 지우고 다시 만들기, 전부 열기, 테스트 고치기 같은 방법으로 통과시키지 않는다.")
    lines.append("- 작업 폴더는 `/work` 다.")
    if floci:
        lines.append("- EC2 인스턴스 안에서 80 포트는 쓸 수 없다. 8080 등 다른 포트를 쓴다.")
    lines.append("- 채점은 대시보드가 한다. 답을 추측하지 말고 실제 상태를 확인한다.")
    return "\n".join(lines) + "\n"


def build_ai_rules(s: Scenario) -> str:
    parts = [_common_rules(s).rstrip(), f"# 할 일\n\n{s.description.strip()}"]
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
