"""compose 파일 읽기 — compose 전용 `!` 태그(`!reset`·`!override` 등)를 값 그대로 받는다.

yaml.safe_load 는 `ports: !reset []` 같은 compose 태그에서 ConstructorError 로 멈춘다.
시험은 파일에 적힌 값을 보므로 태그는 버리고 그 노드의 값(스칼라·목록·사전)만 돌려준다.
"""

from pathlib import Path

import yaml


class ComposeLoader(yaml.SafeLoader):
    """SafeLoader 에 compose `!` 태그만 더한 로더."""


def _untagged(loader: ComposeLoader, _suffix: str, node: yaml.Node) -> object:
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_scalar(node)


ComposeLoader.add_multi_constructor("!", _untagged)


def load_compose(compose_file: Path) -> dict:
    """compose 파일을 사전으로 읽는다(`<<: *anchor` 병합은 safe_load 처럼 푼다)."""
    return yaml.load(compose_file.read_text(encoding="utf-8"), Loader=ComposeLoader)  # noqa: S506 — SafeLoader 하위 클래스
