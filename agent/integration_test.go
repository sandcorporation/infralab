//go:build integration

package main

// 실제 Docker 통합 시험 — 떠 있는 에이전트(학생 compose 스택)를 HTTP 로 친다. 기본 `go test` 에는 들어가지
// 않는다. 돌리는 법은 README 「통합 시험」.
//
//   AGENT_URL=http://host.docker.internal:7777 AGENT_TOKEN=<compose.yml 의 토큰> go test -tags integration -run Integration -v -count=1 -timeout 20m ./...
//
// 순서가 있다(TestIntegration 하나가 하위 시험을 차례로 돈다): status → 환경 준비 전 기록 404 → 환경 준비(Floci 초기화·규칙 파일·
// 준비 표시·setup)와 준비 뒤 기록 200, 실패하는 setup → check(과제 전 0/4 → 과제 수행 → 4/4)
// → kind up(두 번째 호출은 exists) → kind down → floci reset(버킷 사라짐) → 터미널 WS 첫 프레임.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type integ struct {
	t     *testing.T
	url   string
	token string
}

func (i integ) call(method, path string, body any) (int, map[string]any) {
	var buf io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		buf = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, i.url+path, buf)
	if err != nil {
		i.t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+i.token)
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 15 * time.Minute}).Do(req)
	if err != nil {
		i.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func s3Check(id, name, command string, expect map[string]any) map[string]any {
	return map[string]any{"id": id, "name": name, "hint": "", "command": command, "timeout_seconds": 60, "expect": expect}
}

var integS3Checks = []map[string]any{
	s3Check("bucket-exists", "버킷", "aws s3api head-bucket --bucket lab-site", map[string]any{"type": "exit_zero"}),
	s3Check("versioning", "버저닝", "aws s3api get-bucket-versioning --bucket lab-site --query Status --output text", map[string]any{"type": "equals", "value": "Enabled"}),
	s3Check("index", "index.html", "aws s3api head-object --bucket lab-site --key index.html", map[string]any{"type": "exit_zero"}),
	s3Check("website", "웹호스팅", "aws s3api get-bucket-website --bucket lab-site --query IndexDocument.Suffix --output text", map[string]any{"type": "equals", "value": "index.html"}),
}

func TestIntegration(t *testing.T) {
	url, token := os.Getenv("AGENT_URL"), os.Getenv("AGENT_TOKEN")
	if url == "" || token == "" {
		t.Skip("AGENT_URL / AGENT_TOKEN 이 없다 — 떠 있는 에이전트를 가리켜야 한다")
	}
	i := integ{t, strings.TrimRight(url, "/"), token}

	t.Run("status", func(t *testing.T) {
		code, st := i.call("GET", "/api/status", nil)
		if code != 200 {
			t.Fatalf("status = %d: %v", code, st)
		}
		for _, k := range []string{"version", "docker_server", "workstation", "floci", "kind_nodes"} {
			if _, ok := st[k]; !ok {
				t.Errorf("status lacks %q: %v", k, st)
			}
		}
		if st["workstation"] != "running" || st["floci"] != "running" {
			t.Fatalf("stack is not up: workstation=%v floci=%v", st["workstation"], st["floci"])
		}
	})

	t.Run("floci-reset-first", func(t *testing.T) {
		// 깨끗한 상태에서 시작한다.
		code, out := i.call("POST", "/api/floci/reset", nil)
		if code != 200 || out["ok"] != true {
			t.Fatalf("reset: %d %v", code, out)
		}
	})

	t.Run("transcript-before-prepare-is-404", func(t *testing.T) {
		code, out := i.call("GET", "/api/ai-transcript?scenario_id=integration-never", nil)
		if code != 404 {
			t.Fatalf("transcript of an unprepared scenario = %d %v, want 404", code, out)
		}
	})

	t.Run("setup-then-transcript", func(t *testing.T) {
		setup := map[string]any{
			"scenario_id": "integration-lab",
			"reset":       map[string]any{"floci": true, "kind": nil},
			"setup": map[string]any{
				"command":         "broken.sh",
				"scripts":         map[string]string{"broken.sh": "#!/bin/sh\necho setup-ran > /work/integration-setup.txt\n"},
				"timeout_seconds": 30,
			},
			"ai_rules": "# 통합 시험 규칙\n",
		}
		code, out := i.call("POST", "/api/setup", setup)
		if code != 200 || out["ok"] != true {
			t.Fatalf("setup: %d %v", code, out)
		}
		names := ""
		for _, s := range out["steps"].([]any) {
			names += s.(map[string]any)["name"].(string) + ","
		}
		if !strings.Contains(names, "floci/wait-ready,rules,mark,setup,") {
			t.Errorf("step names = %s", names)
		}
		// 규칙 파일 두 개·setup 의 산출물·홈 볼륨의 준비 표시가 workstation 에 실제로 있다.
		files := "grep -q '통합 시험 규칙' /work/CLAUDE.md && grep -q '통합 시험 규칙' /work/AGENTS.md && grep -q setup-ran /work/integration-setup.txt && test -s ~/.infralab/integration-lab.prepared"
		code, out = i.call("POST", "/api/check", map[string]any{"checks": []map[string]any{
			s3Check("files", "산출물", files, map[string]any{"type": "exit_zero"}),
		}})
		if code != 200 || out["passed"].(float64) != 1 {
			t.Fatalf("files after setup: %d %v", code, out)
		}
		// 준비 뒤에는 기록 API 가 200 이고 도구마다 항목이 하나씩 온다.
		code, out = i.call("GET", "/api/ai-transcript?scenario_id=integration-lab", nil)
		if code != 200 {
			t.Fatalf("transcript after setup = %d %v", code, out)
		}
		ts, _ := out["transcripts"].([]any)
		if len(ts) != 2 || ts[0].(map[string]any)["tool"] != "claude" || ts[1].(map[string]any)["tool"] != "codex" {
			t.Errorf("transcripts = %v", out["transcripts"])
		}
		if out["since"] == "" {
			t.Errorf("since is empty: %v", out)
		}
		// 실패하는 setup 은 ok=false 이고 출력이 남는다.
		failing := map[string]any{
			"scenario_id": "integration-lab",
			"reset":       map[string]any{"floci": false, "kind": nil},
			"setup":       map[string]any{"command": "echo boom-output; exit 3", "timeout_seconds": 30},
			"ai_rules":    "x",
		}
		code, out = i.call("POST", "/api/setup", failing)
		steps := out["steps"].([]any)
		last := steps[len(steps)-1].(map[string]any)
		if code != 200 || out["ok"] != false || last["name"] != "setup" || !strings.Contains(last["result"].(string), "boom-output") {
			t.Errorf("failing setup: %d %v", code, out)
		}
	})

	t.Run("check-before-task", func(t *testing.T) {
		code, out := i.call("POST", "/api/check", map[string]any{"checks": integS3Checks})
		if code != 200 {
			t.Fatalf("check = %d: %v", code, out)
		}
		if out["passed"].(float64) != 0 || out["total"].(float64) != 4 {
			t.Fatalf("before task: passed=%v total=%v", out["passed"], out["total"])
		}
	})

	t.Run("check-after-task", func(t *testing.T) {
		// 과제는 검사 명령과 같은 길(workstation 의 bash)로 수행한다 — 그래서 docker 를 직접 부르지 않는다.
		task := "aws s3 mb s3://lab-site && aws s3api put-bucket-versioning --bucket lab-site --versioning-configuration Status=Enabled" +
			" && echo '<h1>hi</h1>' > index.html && aws s3 cp index.html s3://lab-site/index.html" +
			` && aws s3api put-bucket-website --bucket lab-site --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}'`
		code, out := i.call("POST", "/api/check", map[string]any{"checks": []map[string]any{
			s3Check("do-task", "과제 수행", task, map[string]any{"type": "exit_zero"}),
		}})
		if code != 200 || out["passed"].(float64) != 1 {
			t.Fatalf("task: %d %v", code, out)
		}
		code, out = i.call("POST", "/api/check", map[string]any{"checks": integS3Checks})
		if code != 200 || out["passed"].(float64) != 4 {
			t.Fatalf("after task: %d %v", code, out)
		}
	})

	t.Run("check-with-script", func(t *testing.T) {
		code, out := i.call("POST", "/api/check", map[string]any{
			"checks":  []map[string]any{s3Check("script", "스크립트", "hello.sh", map[string]any{"type": "contains", "value": "from-script"})},
			"scripts": map[string]string{"hello.sh": "#!/bin/sh\necho from-script\n"},
		})
		if code != 200 || out["passed"].(float64) != 1 {
			t.Fatalf("script check: %d %v", code, out)
		}
	})

	t.Run("kind-up-twice", func(t *testing.T) {
		code, out := i.call("POST", "/api/kind/up", map[string]any{"control_planes": 1, "workers": 1})
		if code != 200 || out["ok"] != true {
			t.Fatalf("kind up: %d %v", code, out)
		}
		code, out = i.call("POST", "/api/kind/up", map[string]any{"control_planes": 1, "workers": 1})
		if code != 200 || out["ok"] != true {
			t.Fatalf("kind up (again): %d %v", code, out)
		}
		steps := out["steps"].([]any)
		if first := steps[0].(map[string]any); first["result"] != "exists" {
			t.Errorf("second kind up should skip create, got %v", first)
		}
		_, st := i.call("GET", "/api/status", nil)
		if nodes := st["kind_nodes"].([]any); len(nodes) != 2 {
			t.Errorf("kind_nodes = %v, want 2", nodes)
		}
	})

	t.Run("kind-down", func(t *testing.T) {
		code, out := i.call("POST", "/api/kind/down", nil)
		if code != 200 || out["ok"] != true {
			t.Fatalf("kind down: %d %v", code, out)
		}
		_, st := i.call("GET", "/api/status", nil)
		if nodes := st["kind_nodes"].([]any); len(nodes) != 0 {
			t.Errorf("kind_nodes after down = %v", nodes)
		}
	})

	t.Run("floci-reset-clears-state", func(t *testing.T) {
		code, out := i.call("POST", "/api/floci/reset", nil)
		if code != 200 || out["ok"] != true {
			t.Fatalf("reset: %d %v", code, out)
		}
		_, out = i.call("POST", "/api/check", map[string]any{"checks": integS3Checks[:1]})
		if out["passed"].(float64) != 0 {
			t.Errorf("bucket survived the reset: %v", out)
		}
	})

	t.Run("terminal-first-frame", func(t *testing.T) {
		ws := strings.Replace(i.url, "http", "ws", 1) + "/ws/terminal?token=" + token
		conn, _, err := websocket.DefaultDialer.Dial(ws, nil)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"t":"r","c":80,"r":24}`))
		_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"t":"i","d":"echo integration-ok\n"}`))
		_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))
		var got strings.Builder
		for !strings.Contains(got.String(), "integration-ok") {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				t.Fatalf("read: %v (so far %q)", err, got.String())
			}
			if mt == websocket.BinaryMessage {
				got.Write(data)
			}
		}
		fmt.Println("terminal:", strings.TrimSpace(got.String()))
	})
}
