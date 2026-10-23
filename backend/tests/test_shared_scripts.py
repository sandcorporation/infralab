"""공유 검사 스크립트(`scenarios/_shared/`)의 사본이 시나리오 디렉터리마다 원본과 같다.

시나리오는 자기 디렉터리의 스크립트만 에이전트에 싣는다 — 그래서 공유 스크립트는 복사해 쓰고, 복사본이
원본에서 갈라지지 않게 여기서 지킨다.
"""

from pathlib import Path

import pytest
from django.conf import settings

ROOT = Path(settings.SCENARIOS_DIR)
SHARED = ROOT / "_shared"


def _copies():
    for original in sorted(SHARED.glob("*.sh")):
        for copy in sorted(ROOT.glob(f"*/{original.name}")):
            if copy.parent.name != "_shared":
                yield pytest.param(original, copy, id=f"{copy.parent.name}/{original.name}")


@pytest.mark.parametrize("original, copy", list(_copies()))
def test_copy_matches_the_shared_original(original, copy):
    assert copy.read_bytes() == original.read_bytes(), f"{copy} 가 _shared/{original.name} 와 다르다 — 원본을 고치고 다시 복사한다"


def test_the_three_shared_scripts_exist_and_are_lf_only():
    names = {p.name for p in SHARED.glob("*.sh")}
    assert {"record-baseline.sh", "check-baseline.sh", "serve-and-curl.sh"} <= names
    for p in SHARED.glob("*.sh"):
        assert b"\r\n" not in p.read_bytes(), f"{p.name} 에 CRLF 가 있다"
