"""경로 시험(check_exam_proxy_route.sh)의 가짜 backend: AI 프록시의 내부 API 만 흉내 낸다.

토큰이 tok-ok 로 시작하면 허용, 아니면 unknown. 마지막 authorize 의 client_id 를 GET /last 로 돌려준다.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = "route-test-secret"
last: dict[str, str] = {}


class Handler(BaseHTTPRequestHandler):
    def _json(self, status: int, body: object) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        self._json(200, last)

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.headers.get("Authorization") != f"Bearer {SECRET}":
            self._json(401, {"detail": "bad secret"})
            return
        if self.path == "/api/proxy/authorize":
            req = json.loads(raw)
            last.update(token=req["token"], tool=req["tool"], client_id=req["client_id"])
            if req["token"].startswith("tok-ok"):
                self._json(200, {"allowed": True, "reason": None, "model": "fixed-model", "remaining_tokens": 1000})
            else:
                self._json(200, {"allowed": False, "reason": "unknown", "model": None, "remaining_tokens": None})
        elif self.path == "/api/proxy/exchanges":
            self.send_response(204)
            self.end_headers()
        else:
            self._json(404, {})

    def log_message(self, *args: object) -> None:
        pass


ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
