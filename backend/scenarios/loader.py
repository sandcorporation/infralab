"""시나리오 YAML 읽기와 스키마 검증.

시나리오는 DB 에 없다 — 저장소 `scenarios/<id>/scenario.yaml` 이 전부다. id 는 디렉터리 이름이고,
같은 디렉터리의 `*.sh` 는 보조 스크립트로 본문까지 함께 실린다(에이전트가 workstation 에 넣고
command 가 부른다).

검사 하나 = id, name, hint, command, expect. expect 는 YAML 에서 다음 중 하나로 쓴다.

    expect: exit_zero
    expect: {equals: "Enabled"}
    expect: {contains: "Ready"}
    expect: {regex: "^v1\\.\\d+"}
    expect: {jsonpath: {path: ".status.readyReplicas", min: 2}}      # equals | min | contains 중 하나

에이전트에 넘길 때는 `{"type": ..., ...}` 꼴로 정규화한다(`Check.expect`).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

EXPECT_TYPES = ("exit_zero", "equals", "contains", "regex", "jsonpath")
JSONPATH_PREDICATES = ("equals", "min", "contains")
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
#: 에이전트가 지원하는 경로 문법 — `.a.b[0].c` 꼴(점으로 이은 이름, 뒤에 [정수] 인덱스).
JSONPATH_PATTERN = re.compile(r"^(\.[A-Za-z0-9_-]+(\[\d+\])*)+$")
#: Go 의 RE2 가 거부하는 문법 — Python `re` 는 받아들이므로 따로 막는다.
RE2_UNSUPPORTED = re.compile(r"\(\?<?[=!]|\\[1-9]")
DEFAULT_CHECK_TIMEOUT_SECONDS = 30
MAX_CHECK_TIMEOUT_SECONDS = 300


class ScenarioError(Exception):
    """시나리오 파일이 스키마에 맞지 않을 때. 메시지에 파일과 자리를 적는다."""


class _StrictLoader(yaml.SafeLoader):
    """같은 맵에 키가 두 번 나오면 거부한다 — PyYAML 기본은 뒤 값으로 조용히 덮어쓴다."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"키가 두 번 나온다: {key!r}", key_node.start_mark
                )
            seen.add(key)
        return super().construct_mapping(node, deep)


def _read_text(path: Path, where: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ScenarioError(f"{where}: {path.name} 이 UTF-8 이 아니다: {exc}") from exc
    except OSError as exc:
        raise ScenarioError(f"{where}: {path.name} 을 읽을 수 없다: {exc}") from exc


def _scalar_text(value: Any, where: str) -> str:
    """기대값은 문자열이거나 정수만 — bool·float 는 YAML 이 `yes`→True, `1.10`→1.1 로 바꿔 버린다."""

    if isinstance(value, str):
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    raise ScenarioError(f"{where} 는 문자열이어야 한다 — 따옴표로 감싼다 (지금 {type(value).__name__}: {value!r})")


@dataclass(frozen=True)
class KindRequirement:
    control_planes: int = 1
    workers: int = 0

    def as_dict(self) -> dict[str, int]:
        return {"control_planes": self.control_planes, "workers": self.workers}


@dataclass(frozen=True)
class Requires:
    floci: bool = False
    kind: KindRequirement | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"floci": self.floci, "kind": self.kind.as_dict() if self.kind else None}


@dataclass(frozen=True)
class Check:
    id: str
    name: str
    command: str
    expect: dict[str, Any]
    hint: str = ""
    timeout_seconds: int = DEFAULT_CHECK_TIMEOUT_SECONDS

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "hint": self.hint,
            "command": self.command,
            "timeout_seconds": self.timeout_seconds,
            "expect": dict(self.expect),
        }


@dataclass(frozen=True)
class Scenario:
    id: str
    title: str
    description: str
    requires: Requires
    checks: tuple[Check, ...]
    #: 보조 스크립트 — 파일 이름 → 본문. 에이전트가 workstation 작업 폴더에 같은 이름으로 넣는다.
    scripts: dict[str, str] = field(default_factory=dict)

    def check_definitions(self) -> list[dict[str, Any]]:
        """에이전트 `/api/check` 에 넘기는 검사 정의 전문."""

        return [c.as_dict() for c in self.checks]


# ---------- 파싱 ----------


def _require(mapping: dict, key: str, where: str, kind: type | tuple[type, ...]):
    if key not in mapping:
        raise ScenarioError(f"{where}: `{key}` 가 없다")
    value = mapping[key]
    if not isinstance(value, kind) or (kind is str and not value.strip()):
        raise ScenarioError(f"{where}: `{key}` 의 종류가 틀렸다 ({type(value).__name__})")
    return value


def _reject_unknown(mapping: dict, allowed: set[str], where: str) -> None:
    unknown = set(mapping) - allowed
    if unknown:
        raise ScenarioError(f"{where}: 모르는 필드 {sorted(unknown)}")


def _parse_expect(raw: Any, where: str) -> dict[str, Any]:
    if raw == "exit_zero":
        return {"type": "exit_zero"}
    if isinstance(raw, str):
        raise ScenarioError(f"{where}: expect 종류를 모른다 ({raw!r}) — {', '.join(EXPECT_TYPES)} 중 하나")
    if not isinstance(raw, dict) or len(raw) != 1:
        raise ScenarioError(f"{where}: expect 는 `exit_zero` 또는 키 하나짜리 맵이어야 한다")
    (kind, value), = raw.items()
    if kind not in EXPECT_TYPES:
        raise ScenarioError(f"{where}: expect 종류를 모른다 ({kind!r}) — {', '.join(EXPECT_TYPES)} 중 하나")
    if kind == "exit_zero":
        raise ScenarioError(f"{where}: exit_zero 는 값 없이 `expect: exit_zero` 로 쓴다")
    if kind in ("equals", "contains"):
        return {"type": kind, "value": _scalar_text(value, f"{where}: expect.{kind}")}
    if kind == "regex":
        if not isinstance(value, str):
            raise ScenarioError(f"{where}: expect.regex 는 문자열이어야 한다")
        try:
            re.compile(value)
        except re.error as exc:
            raise ScenarioError(f"{where}: expect.regex 가 올바른 정규식이 아니다: {exc}") from exc
        if RE2_UNSUPPORTED.search(value):
            raise ScenarioError(
                f"{where}: expect.regex 에 lookahead/lookbehind/역참조가 있다 — 에이전트(Go RE2)는 지원하지 않는다"
            )
        return {"type": "regex", "pattern": value}
    # jsonpath
    if not isinstance(value, dict):
        raise ScenarioError(f"{where}: expect.jsonpath 는 {{path, equals|min|contains}} 맵이어야 한다")
    _reject_unknown(value, {"path", *JSONPATH_PREDICATES}, f"{where}: expect.jsonpath")
    path = _require(value, "path", f"{where}: expect.jsonpath", str)
    if not JSONPATH_PATTERN.match(path):
        raise ScenarioError(f"{where}: expect.jsonpath.path 는 `.status.readyReplicas`·`.items[0].name` 꼴이어야 한다 ({path!r})")
    predicates = [p for p in JSONPATH_PREDICATES if p in value]
    if len(predicates) != 1:
        raise ScenarioError(f"{where}: expect.jsonpath 는 equals·min·contains 중 정확히 하나를 가져야 한다")
    pred = predicates[0]
    pv = value[pred]
    if pred == "min":
        if isinstance(pv, bool) or not isinstance(pv, (int, float)):
            raise ScenarioError(f"{where}: expect.jsonpath.min 은 숫자여야 한다")
        return {"type": "jsonpath", "path": path, "min": pv}
    return {"type": "jsonpath", "path": path, pred: _scalar_text(pv, f"{where}: expect.jsonpath.{pred}")}


def _parse_check(raw: Any, where: str) -> Check:
    if not isinstance(raw, dict):
        raise ScenarioError(f"{where}: 검사는 맵이어야 한다")
    _reject_unknown(raw, {"id", "name", "hint", "command", "expect", "timeout_seconds"}, where)
    check_id = _require(raw, "id", where, str)
    if not ID_PATTERN.match(check_id):
        raise ScenarioError(f"{where}: 검사 id 는 소문자·숫자·하이픈만 ({check_id!r})")
    where = f"{where} ({check_id})"
    timeout = raw.get("timeout_seconds", DEFAULT_CHECK_TIMEOUT_SECONDS)
    if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= MAX_CHECK_TIMEOUT_SECONDS:
        raise ScenarioError(f"{where}: timeout_seconds 는 1..{MAX_CHECK_TIMEOUT_SECONDS} 정수여야 한다")
    hint = raw.get("hint", "")
    if not isinstance(hint, str):
        raise ScenarioError(f"{where}: hint 는 문자열이어야 한다")
    return Check(
        id=check_id,
        name=_require(raw, "name", where, str),
        hint=hint,
        command=_require(raw, "command", where, str),
        expect=_parse_expect(_require(raw, "expect", where, (str, dict)), where),
        timeout_seconds=timeout,
    )


def _parse_requires(raw: Any, where: str) -> Requires:
    if raw is None:
        return Requires()
    if not isinstance(raw, dict):
        raise ScenarioError(f"{where}: requires 는 맵이어야 한다")
    _reject_unknown(raw, {"floci", "kind"}, f"{where}: requires")
    floci = raw.get("floci", False)
    if not isinstance(floci, bool):
        raise ScenarioError(f"{where}: requires.floci 는 true/false 여야 한다")
    kind_raw = raw.get("kind")
    kind = None
    if kind_raw is not None:
        if not isinstance(kind_raw, dict):
            raise ScenarioError(f"{where}: requires.kind 는 {{control_planes, workers}} 맵이거나 null 이어야 한다")
        _reject_unknown(kind_raw, {"control_planes", "workers"}, f"{where}: requires.kind")
        cp = kind_raw.get("control_planes", 1)
        workers = kind_raw.get("workers", 0)
        for name, v, lo, hi in (("control_planes", cp, 1, 3), ("workers", workers, 0, 5)):
            if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
                raise ScenarioError(f"{where}: requires.kind.{name} 은 {lo}..{hi} 정수여야 한다")
        kind = KindRequirement(control_planes=cp, workers=workers)
    return Requires(floci=floci, kind=kind)


def load_scenario(directory: Path) -> Scenario:
    """디렉터리 하나를 시나리오로 읽는다. 스키마에 맞지 않으면 `ScenarioError`."""

    path = directory / "scenario.yaml"
    where = str(path)
    if not path.is_file():
        raise ScenarioError(f"{where}: 파일이 없다")
    try:
        raw = yaml.load(_read_text(path, where), Loader=_StrictLoader)  # noqa: S506 - SafeLoader 하위
    except yaml.YAMLError as exc:
        raise ScenarioError(f"{where}: YAML 을 읽을 수 없다: {exc}") from exc
    if not isinstance(raw, dict):
        raise ScenarioError(f"{where}: 최상위는 맵이어야 한다")
    _reject_unknown(raw, {"id", "title", "description", "description_file", "requires", "checks"}, where)

    scenario_id = _require(raw, "id", where, str)
    if not ID_PATTERN.match(scenario_id):
        raise ScenarioError(f"{where}: id 는 소문자·숫자·하이픈만 ({scenario_id!r})")
    if scenario_id != directory.name:
        raise ScenarioError(f"{where}: id({scenario_id!r}) 가 디렉터리 이름({directory.name!r})과 다르다")

    if "description_file" in raw:
        if "description" in raw:
            raise ScenarioError(f"{where}: description 과 description_file 중 하나만 쓴다")
        desc_path = directory / _require(raw, "description_file", where, str)
        if not desc_path.is_file() or desc_path.resolve().parent != directory.resolve():
            raise ScenarioError(f"{where}: description_file 은 같은 디렉터리의 파일이어야 한다")
        description = _read_text(desc_path, where)
    else:
        description = _require(raw, "description", where, str)

    checks_raw = _require(raw, "checks", where, list)
    if not checks_raw:
        raise ScenarioError(f"{where}: checks 가 비어 있다")
    checks = tuple(_parse_check(c, f"{where}: checks[{i}]") for i, c in enumerate(checks_raw))
    seen: set[str] = set()
    for c in checks:
        if c.id in seen:
            raise ScenarioError(f"{where}: 검사 id 가 겹친다 ({c.id!r})")
        seen.add(c.id)

    scripts = {p.name: _read_text(p, where) for p in sorted(directory.glob("*.sh"))}

    return Scenario(
        id=scenario_id,
        title=_require(raw, "title", where, str),
        description=description,
        requires=_parse_requires(raw.get("requires"), where),
        checks=checks,
        scripts=scripts,
    )


def load_all(root: Path) -> dict[str, Scenario]:
    """`root` 아래 모든 시나리오 디렉터리를 읽는다. 하나라도 깨지면 `ScenarioError`.

    `_` 나 `.` 로 시작하는 디렉터리는 시나리오가 아니다(공용 스크립트·템플릿 자리). 그 외 디렉터리는
    전부 시나리오여야 한다 — 오타 난 디렉터리가 조용히 빠지지 않게.
    """

    if not root.is_dir():
        raise ScenarioError(f"시나리오 디렉터리가 없다: {root}")
    scenarios: dict[str, Scenario] = {}
    for directory in sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith((".", "_"))):
        scenario = load_scenario(directory)
        scenarios[scenario.id] = scenario
    return scenarios
