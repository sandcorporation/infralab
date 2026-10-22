import { useCallback, useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";

type Conn = "connecting" | "open" | "closed" | "failed";

// 브라우저 터미널. 에이전트 WS 에 붙어 workstation 의 bash 를 중계한다 — 출력은 바이너리 프레임, 입력은
// JSON 텍스트 프레임({t:"i",d} 입력, {t:"r",c,r} 크기). 끊기면 「재연결」 버튼이 뜬다. 열린 적 없이 실패한
// 연결은 「끊김」이 아니라 「연결 실패」다.
export function Terminal({ agentUrl, token }: { agentUrl: string; token: string }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [conn, setConn] = useState<Conn>("connecting");

  const send = (msg: object) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  };

  const connect = useCallback(() => {
    const term = termRef.current;
    if (!term) return;
    wsRef.current?.close();
    setConn("connecting");
    const url = `${agentUrl.replace(/^http/, "ws")}/ws/terminal?token=${encodeURIComponent(token)}`;
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    wsRef.current = ws;
    let opened = false;
    ws.onopen = () => {
      opened = true;
      setConn("open");
      // 이전 세션의 출력(끊긴 이유 등)은 남겨 두고 구분선만 긋는다.
      if (term.buffer.active.length > 1) term.write("\r\n\x1b[90m────────────\x1b[0m\r\n");
      term.focus();
      ws.send(JSON.stringify({ t: "r", c: term.cols, r: term.rows }));
    };
    ws.onmessage = (ev) => term.write(new Uint8Array(ev.data as ArrayBuffer));
    ws.onclose = () => {
      if (wsRef.current !== ws) return;
      if (opened) {
        setConn("closed");
        term.write("\r\n\x1b[90m[연결이 끊어졌습니다]\x1b[0m\r\n");
      } else {
        setConn("failed");
      }
    };
    ws.onerror = () => ws.close();
  }, [agentUrl, token]);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const term = new XTerm({ cursorBlink: true, fontSize: 13, convertEol: false, theme: { background: "#111827" } });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    fit.fit();
    termRef.current = term;
    const onData = term.onData((d) => send({ t: "i", d }));
    const onResize = term.onResize(({ cols, rows }) => send({ t: "r", c: cols, r: rows }));
    // 패널 크기가 바뀌면 열·행을 다시 맞춘다 — 창 크기와 사이드바 접힘 둘 다. 이미 정리된 터미널에는 손대지 않는다
    // (StrictMode 가 effect 를 두 번 돌릴 때 늦게 오는 콜백).
    const observer = new ResizeObserver(() => {
      if (termRef.current === term && host.isConnected) fit.fit();
    });
    observer.observe(host);
    connect();
    return () => {
      observer.disconnect();
      onData.dispose();
      onResize.dispose();
      wsRef.current?.close();
      wsRef.current = null;
      termRef.current = null;
      term.dispose();
    };
  }, [connect]);

  const label = { connecting: "연결 중…", open: "연결됨", closed: "끊김", failed: "연결 실패" }[conn];
  return (
    <div className="terminal">
      <div className="row terminal-bar">
        <span className={`badge ${conn === "open" ? "ok" : conn === "connecting" ? "muted" : "bad"}`}>{label}</span>
        {(conn === "closed" || conn === "failed") && (
          <button className="secondary" onClick={connect}>
            재연결
          </button>
        )}
        {conn === "failed" && <span className="muted">에이전트 주소·토큰이 맞는지 설치 안내에서 확인</span>}
      </div>
      <div ref={hostRef} className="terminal-host" />
    </div>
  );
}
