"""프로젝트 전역 pytest 픽스처. 시험은 Django 테스트 클라이언트로 전체 요청 스택(URLconf + 라우터
+ 인증)을 통과한다 — 바깥에서 보이는 HTTP 요청과 응답만 본다."""

import pytest


@pytest.fixture
def api(client):
    """`tests.scenarios.Api` — 로그인·인증 헤더 같은 반복을 묶은 시나리오 헬퍼."""

    from tests.scenarios import Api

    return Api(client)
