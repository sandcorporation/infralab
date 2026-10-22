package main

import (
	"encoding/json"
	"net/http"
	"os/exec"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

// 터미널은 pty 가 필요해 runner 를 거치지 않고 docker exec 를 직접 띄운다 — 통합 시험으로 민다.
// 프로토콜: 입력은 JSON 텍스트 프레임({t:"i",d} 입력, {t:"r",c,r} 크기), 출력은 바이너리 프레임.

func (s *server) handleTerminal(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("token") != s.cfg.Token {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	upgrader := websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin: func(r *http.Request) bool {
			o := r.Header.Get("Origin")
			return o == "" || s.originAllowed(o)
		},
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	cmd := exec.Command("docker", "exec", "-it", "-e", "TERM=xterm-256color", s.cfg.Workstation, "bash", "-l")
	f, err := pty.Start(cmd)
	if err != nil {
		_ = conn.WriteMessage(websocket.BinaryMessage, []byte("pty error: "+err.Error()+"\r\n"))
		return
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = f.Close()
		// 에이전트는 컨테이너의 PID 1 이라 Wait 하지 않으면 세션마다 좀비가 남는다.
		_ = cmd.Wait()
	}()

	go func() {
		buf := make([]byte, 8192)
		for {
			n, err := f.Read(buf)
			if n > 0 {
				if conn.WriteMessage(websocket.BinaryMessage, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				_ = conn.Close()
				return
			}
		}
	}()

	for {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if mt != websocket.TextMessage {
			_, _ = f.Write(data)
			continue
		}
		var m struct {
			T string `json:"t"`
			D string `json:"d"`
			C uint16 `json:"c"`
			R uint16 `json:"r"`
		}
		if json.Unmarshal(data, &m) != nil {
			continue
		}
		switch m.T {
		case "i":
			_, _ = f.Write([]byte(m.D))
		case "r":
			_ = pty.Setsize(f, &pty.Winsize{Cols: m.C, Rows: m.R})
		}
	}
}
