"""운영 backend 이미지에 배포 sha 를 굽는다(#207).

image.yml 의 backend 빌드가 이미지 태그와 같은 sha 를 build-arg INFRALAB_VERSION 으로 넘기고,
backend.prod.Dockerfile 이 그 ARG 를 ENV INFRALAB_VERSION 으로 옮기는지 정적으로 본다.
값이 비면 dev 로 읽는 것은 test_spec_backend_version_api.py 가 본다.
"""

import re
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]


def _backend_matrix_entry() -> dict[str, str]:
    doc = yaml.safe_load((REPO / ".github/workflows/image.yml").read_text(encoding="utf-8"))
    entries = doc["jobs"]["build"]["strategy"]["matrix"]["include"]
    (entry,) = [e for e in entries if e["name"] == "infralab-backend"]
    return entry


def test_image_yml_passes_image_sha_as_infralab_version_to_backend() -> None:
    entry = _backend_matrix_entry()
    assert entry["dockerfile"] == "docker/backend.prod.Dockerfile"
    assert entry["build_args"].splitlines() == ["INFRALAB_VERSION=${{ github.sha }}"]


def test_image_yml_tags_with_same_sha_and_forwards_build_args() -> None:
    doc = yaml.safe_load((REPO / ".github/workflows/image.yml").read_text(encoding="utf-8"))
    steps = doc["jobs"]["build"]["steps"]
    (push,) = [s for s in steps if "build-args" in s.get("with", {})]
    assert push["with"]["build-args"] == "${{ matrix.build_args }}"
    assert push["with"]["tags"].startswith("${{ env.IMAGE_REPO }}:${{ github.sha }}")


def test_backend_dockerfile_bakes_arg_into_env_in_runtime_stage() -> None:
    text = (REPO / "docker/backend.prod.Dockerfile").read_text(encoding="utf-8")
    runtime = text.split(" AS runtime", 1)[1]
    assert re.search(r"^ARG INFRALAB_VERSION=?$", runtime, re.M)
    assert re.search(r"^ENV INFRALAB_VERSION=\$\{INFRALAB_VERSION\}$", runtime, re.M)
