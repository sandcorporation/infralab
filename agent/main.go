// infra-agent PoC — 학생 로컬 Docker 를 docker.sock 으로 제어하는 에이전트.
// LocalStack·workstation·kind 를 올리고, 브라우저 터미널(xterm.js)을 docker exec 로 중계한다.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

//go:embed static
var staticFiles embed.FS

const (
	labNet   = "infralab"
	wsName   = "infralab-workstation"
	lsName   = "infralab-localstack"
	kindName = "infralab"
)

var (
	token          = os.Getenv("AGENT_TOKEN")
	wsImage        = getenv("WORKSTATION_IMAGE", "infralab/workstation:poc")
	lsImage        = getenv("LOCALSTACK_IMAGE", "localstack/localstack:4")
	allowedOrigins = strings.Split(getenv("AGENT_ALLOWED_ORIGINS", "http://127.0.0.1:7777,http://localhost:7777"), ",")
)

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	if token == "" {
		log.Fatal("AGENT_TOKEN is required")
	}
	sub, _ := fs.Sub(staticFiles, "static")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(sub)))
	mux.HandleFunc("/api/status", auth(handleStatus))
	mux.HandleFunc("/api/env/up", auth(handleEnvUp))
	mux.HandleFunc("/api/env/down", auth(handleEnvDown))
	mux.HandleFunc("/api/kind/up", auth(handleKindUp))
	mux.HandleFunc("/api/kind/down", auth(handleKindDown))
	mux.HandleFunc("/api/grade/", auth(handleGrade))
	mux.HandleFunc("/ws/terminal", handleTerminal)
	addr := getenv("AGENT_ADDR", ":7777")
	log.Printf("infra-agent listening on %s (origins: %v)", addr, allowedOrigins)
	log.Fatal(http.ListenAndServe(addr, cors(mux)))
}

// ---------- HTTP 공통 ----------

func originAllowed(o string) bool {
	for _, a := range allowedOrigins {
		if strings.TrimSpace(a) == o {
			return true
		}
	}
	return false
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); o != "" && originAllowed(o) {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", o)
			h.Set("Vary", "Origin")
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			// Chrome Private/Local Network Access: 공개 https 페이지 → localhost 요청의 preflight 에 필요
			h.Set("Access-Control-Allow-Private-Network", "true")
			h.Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		h(w, r)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// ---------- docker 헬퍼 ----------

func docker(ctx context.Context, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func kind(ctx context.Context, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "kind", args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func wsExec(ctx context.Context, args ...string) (string, error) {
	return docker(ctx, append([]string{"exec", wsName}, args...)...)
}

func containerState(ctx context.Context, name string) string {
	out, err := docker(ctx, "inspect", "-f", "{{.State.Status}}", name)
	if err != nil {
		return ""
	}
	return out
}

func ensureContainer(ctx context.Context, name string, runArgs []string) (string, error) {
	switch containerState(ctx, name) {
	case "running":
		return "already running", nil
	case "":
		out, err := docker(ctx, append([]string{"run", "-d", "--name", name}, runArgs...)...)
		if err != nil {
			return out, err
		}
		return "created " + out[:12], nil
	default:
		out, err := docker(ctx, "start", name)
		if err != nil {
			return out, err
		}
		return "started", nil
	}
}

type step struct {
	Name   string `json:"name"`
	Result string `json:"result"`
	Ms     int64  `json:"ms"`
}

type stepper struct{ steps []step }

func (s *stepper) run(name string, f func() (string, error)) bool {
	start := time.Now()
	res, err := f()
	if err != nil {
		res = fmt.Sprintf("ERROR: %v\n%s", err, res)
	}
	s.steps = append(s.steps, step{name, res, time.Since(start).Milliseconds()})
	return err == nil
}

// ---------- 핸들러 ----------

func handleStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	type c struct {
		Name  string `json:"name"`
		State string `json:"state"`
	}
	var containers []c
	out, _ := docker(ctx, "ps", "-a", "--filter", "name=infralab", "--format", "{{.Names}}\t{{.Status}}")
	for _, line := range strings.Split(out, "\n") {
		if p := strings.SplitN(line, "\t", 2); len(p) == 2 {
			containers = append(containers, c{p[0], p[1]})
		}
	}
	clusters, _ := docker(ctx, "ps", "--filter", "label=io.x-k8s.kind.cluster="+kindName, "--format", "{{.Names}}")
	ver, _ := docker(ctx, "version", "--format", "{{.Server.Version}}")
	writeJSON(w, 200, map[string]any{
		"docker_server": ver,
		"containers":    containers,
		"kind_nodes":    strings.Fields(clusters),
	})
}

func handleEnvUp(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	var s stepper
	ok := s.run("network", func() (string, error) {
		if _, err := docker(ctx, "network", "inspect", labNet); err == nil {
			return "exists", nil
		}
		return docker(ctx, "network", "create", labNet)
	})
	ok = ok && s.run("localstack", func() (string, error) {
		return ensureContainer(ctx, lsName, []string{
			"--network", labNet, "--network-alias", "localstack",
			"-v", "/var/run/docker.sock:/var/run/docker.sock",
			"-e", "LAMBDA_DOCKER_NETWORK=" + labNet,
			lsImage})
	})
	ok = ok && s.run("workstation", func() (string, error) {
		return ensureContainer(ctx, wsName, []string{
			"--network", labNet, "-w", "/work",
			"-e", "AWS_ACCESS_KEY_ID=test", "-e", "AWS_SECRET_ACCESS_KEY=test",
			"-e", "AWS_DEFAULT_REGION=ap-northeast-2",
			"-e", "AWS_ENDPOINT_URL=http://localstack:4566",
			"-e", "TERM=xterm-256color",
			wsImage, "sleep", "infinity"})
	})
	ok = ok && s.run("localstack-health", func() (string, error) {
		deadline := time.Now().Add(120 * time.Second)
		for time.Now().Before(deadline) {
			out, err := wsExec(ctx, "curl", "-sf", "http://localstack:4566/_localstack/health")
			if err == nil && strings.Contains(out, `"s3"`) {
				return "healthy", nil
			}
			time.Sleep(2 * time.Second)
		}
		return "", errors.New("timeout waiting for localstack")
	})
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": s.steps})
}

func handleEnvDown(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	var s stepper
	s.run("kind-delete", func() (string, error) { return kind(ctx, "delete", "cluster", "--name", kindName) })
	s.run("containers", func() (string, error) { return docker(ctx, "rm", "-f", wsName, lsName) })
	s.run("network", func() (string, error) { return docker(ctx, "network", "rm", labNet) })
	writeJSON(w, 200, map[string]any{"steps": s.steps})
}

func handleKindUp(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()
	var req struct {
		ControlPlanes int `json:"control_planes"`
		Workers       int `json:"workers"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.ControlPlanes <= 0 {
		req.ControlPlanes = 1
	}
	var s stepper
	ok := s.run("create", func() (string, error) {
		if out, _ := kind(ctx, "get", "clusters"); strings.Contains(out, kindName) {
			return "exists", nil
		}
		cfg := "kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n"
		cfg += strings.Repeat("  - role: control-plane\n", req.ControlPlanes)
		cfg += strings.Repeat("  - role: worker\n", req.Workers)
		if err := os.WriteFile("/tmp/kind-config.yaml", []byte(cfg), 0o644); err != nil {
			return "", err
		}
		return kind(ctx, "create", "cluster", "--name", kindName, "--config", "/tmp/kind-config.yaml", "--wait", "180s")
	})
	ok = ok && s.run("kubeconfig-into-workstation", func() (string, error) {
		kc, err := exec.CommandContext(ctx, "kind", "get", "kubeconfig", "--name", kindName, "--internal").Output()
		if err != nil {
			return "", err
		}
		cmd := exec.CommandContext(ctx, "docker", "exec", "-i", wsName, "sh", "-c", "mkdir -p /root/.kube && cat > /root/.kube/config")
		cmd.Stdin = strings.NewReader(string(kc))
		out, err := cmd.CombinedOutput()
		if err != nil {
			return string(out), err
		}
		return fmt.Sprintf("written (%d bytes)", len(kc)), nil
	})
	ok = ok && s.run("join-kind-network", func() (string, error) {
		out, err := docker(ctx, "network", "connect", "kind", wsName)
		if err != nil && strings.Contains(out, "already exists") {
			return "already connected", nil
		}
		if err != nil {
			return out, err
		}
		return "connected", nil
	})
	ok = ok && s.run("verify", func() (string, error) { return wsExec(ctx, "kubectl", "get", "nodes", "-o", "wide") })
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": s.steps})
}

func handleKindDown(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	out, err := kind(ctx, "delete", "cluster", "--name", kindName)
	writeJSON(w, 200, map[string]any{"ok": err == nil, "output": out})
}

type check struct {
	Name   string `json:"name"`
	Pass   bool   `json:"pass"`
	Detail string `json:"detail"`
}

func handleGrade(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	scenario := strings.TrimPrefix(r.URL.Path, "/api/grade/")
	var checks []check
	add := func(name string, pass bool, detail string) { checks = append(checks, check{name, pass, detail}) }
	switch scenario {
	case "s3-site":
		const b = "lab-site"
		out, err := wsExec(ctx, "aws", "s3api", "head-bucket", "--bucket", b)
		add("버킷 "+b+" 존재", err == nil, firstLine(out))
		out, err = wsExec(ctx, "aws", "s3api", "get-bucket-versioning", "--bucket", b, "--query", "Status", "--output", "text")
		add("버저닝 Enabled", err == nil && out == "Enabled", out)
		out, err = wsExec(ctx, "aws", "s3api", "head-object", "--bucket", b, "--key", "index.html")
		add("index.html 업로드", err == nil, firstLine(out))
		out, err = wsExec(ctx, "aws", "s3api", "get-bucket-website", "--bucket", b, "--query", "IndexDocument.Suffix", "--output", "text")
		add("정적 웹 호스팅 설정", err == nil && out == "index.html", out)
	case "k8s-basic":
		out, err := wsExec(ctx, "kubectl", "get", "nodes", "--no-headers")
		ready := 0
		for _, l := range strings.Split(out, "\n") {
			if f := strings.Fields(l); len(f) >= 2 && f[1] == "Ready" {
				ready++
			}
		}
		add("Ready 노드 2개 이상", err == nil && ready >= 2, out)
		out, err = wsExec(ctx, "kubectl", "get", "deploy", "web", "-o", "jsonpath={.status.readyReplicas}")
		n, _ := strconv.Atoi(strings.TrimSpace(out))
		add("Deployment web 의 ready 레플리카 2개 이상", err == nil && n >= 2, out)
		out, err = wsExec(ctx, "kubectl", "get", "svc", "web", "-o", "jsonpath={.spec.type}")
		add("Service web 존재", err == nil, out)
	default:
		writeJSON(w, 404, map[string]any{"error": "unknown scenario: " + scenario})
		return
	}
	pass := 0
	for _, c := range checks {
		if c.Pass {
			pass++
		}
	}
	writeJSON(w, 200, map[string]any{"scenario": scenario, "passed": pass, "total": len(checks), "checks": checks})
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// ---------- 웹 터미널 ----------

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin: func(r *http.Request) bool {
		o := r.Header.Get("Origin")
		return o == "" || originAllowed(o)
	},
}

func handleTerminal(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("token") != token {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	cmd := exec.Command("docker", "exec", "-it", "-e", "TERM=xterm-256color", wsName, "bash", "-l")
	f, err := pty.Start(cmd)
	if err != nil {
		_ = conn.WriteMessage(websocket.BinaryMessage, []byte("pty error: "+err.Error()+"\r\n"))
		return
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = f.Close()
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
