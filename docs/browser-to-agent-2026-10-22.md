# 브라우저 → 로컬 에이전트 접근 확인 (2026-10-22)

학생 compose.yml(#8)로 올린 에이전트에 대시보드가 붙는지 확인한 기록.

| 확인 | 결과 |
| --- | --- |
| 대시보드 `http://127.0.0.1:53040` → `http://127.0.0.1:7777/api/status` (Playwright Chromium) | 200. `Access-Control-Allow-Origin: http://127.0.0.1:53040`, `Access-Control-Allow-Private-Network: true` 응답. 화면 배지 「에이전트 연결됨 · v0.2.0-dev」 |
| 같은 요청을 curl 로 Origin 헤더만 붙여 | 같은 헤더. 허용 목록에 없는 Origin 에는 CORS 헤더 없음(에이전트 시험) |
| Chrome 의 Local Network Access 권한 프롬프트 | **뜨지 않는다** — 대시보드 자체가 127.0.0.1(로컬) 오리진이라 「공개 사이트 → 로컬」 경계가 아니다. 공개 https 오리진에서의 프롬프트는 배포 뒤 실제 Chrome 으로 확인해야 한다. 설치 안내 화면의 문구는 그 경우를 설명하되 「127.0.0.1·localhost 로 열었을 때는 묻지 않는다」를 같이 적었다 |

compose.yml 의 `AGENT_ALLOWED_ORIGINS` 는 서버 설정 `DASHBOARD_ORIGIN`(콤마 목록)에서 만든다. 127.0.0.1 과
localhost 는 서로의 표기를 자동으로 더하고, 뒤 슬래시·경로는 버린다(브라우저 Origin 헤더와 글자 그대로 비교된다).
