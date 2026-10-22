package main

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

// 터미널은 pty 가 필요해 runner 를 거치지 않고 docker exec 를 직접 띄운다 — 통합 시험으로 민다.
// 프로토콜: 입력은 JSON 텍스트 프레임({t:"i",d} 입력, {t:"r",c,r} 크기), 출력은 바이너리 프레임.
// 브라우저는 WebSocket 업그레이드에 헤더를 못 붙이므로 토큰은 쿼리로 온다 — 비교는 상수 시간으로.

const (
	wsPingInterval = 20 * time.Second
	// pong 이 이 시간 안에 안 오면 연결이 죽은 것이다 — 노트북이 잠들거나 와이파이가 FIN 없이 끊긴 경우,
	// 이 시한이 없으면 docker exec bash 와 pty 가 커널 TCP 타임아웃까지(수십 분~시간) 남는다.
	wsReadTimeout = 60 * time.Second
)

func (s *server) handleTerminal(w http.ResponseWriter, r *http.Request) {
	given := r.URL.Query().Get("token")
	if subtle.ConstantTimeCompare([]byte(given), []byte(s.cfg.Token)) != 1 {
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

	// gorilla 의 쓰기는 동시에 하나만 — pty 출력과 ping 이 겹치지 않게 잠근다.
	var writeMu sync.Mutex
	write := func(mt int, data []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		return conn.WriteMessage(mt, data)
	}

	cmd := exec.Command("docker", "exec", "-it", "-e", "TERM=xterm-256color", s.cfg.Workstation, "bash", "-l")
	f, err := pty.Start(cmd)
	if err != nil {
		_ = write(websocket.BinaryMessage, []byte("pty error: "+err.Error()+"\r\n"))
		return
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = f.Close()
		// 에이전트는 컨테이너의 PID 1 이라 Wait 하지 않으면 세션마다 좀비가 남는다.
		_ = cmd.Wait()
	}()

	_ = conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
	})

	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(wsPingInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if write(websocket.PingMessage, nil) != nil {
					_ = conn.Close()
					return
				}
			}
		}
	}()
	go func() {
		buf := make([]byte, 8192)
		for {
			n, err := f.Read(buf)
			if n > 0 {
				if write(websocket.BinaryMessage, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				_ = conn.Close()
				return
			}
		}
	}()
	defer close(done)

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
