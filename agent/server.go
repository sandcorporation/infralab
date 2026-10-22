package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// version 은 빌드 때 -ldflags "-X main.version=..." 로 박는다.
var version = "dev"

// config 는 에이전트가 환경에서 받는 값이다. compose.yml 이 환경변수로 넘긴다.
type config struct {
	Token          string
	AllowedOrigins []string
	Workstation    string // compose 가 만든 workstation 컨테이너 이름
	Floci          string // compose 가 만든 Floci 컨테이너 이름
	KindCluster    string
}

type server struct {
	cfg    config
	runner Runner
	// envMu 는 환경을 바꾸는 작업(kind up/down, Floci reset)을 하나씩만 돌린다 — 대시보드 더블클릭이
	// kind create 를 두 번 띄우면 두 번째의 실패 정리가 첫 번째 클러스터를 지운다.
	envMu sync.Mutex
}

// newHandler 는 전체 HTTP 표면을 만든다. 시험은 이것을 httptest 에 올린다.
func newHandler(cfg config, r Runner) http.Handler {
	s := &server{cfg: cfg, runner: r}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.auth(get(s.handleStatus)))
	mux.HandleFunc("/api/kind/up", s.auth(post(s.exclusive(s.handleKindUp))))
	mux.HandleFunc("/api/kind/down", s.auth(post(s.exclusive(s.handleKindDown))))
	// 채점도 환경 작업과 겹치지 않게 — 반쯤 내려간 클러스터를 보고 내린 판정은 증거가 못 된다.
	mux.HandleFunc("/api/check", s.auth(post(s.exclusive(s.handleCheck))))
	mux.HandleFunc("/ws/terminal", s.handleTerminal)
	return s.cors(mux)
}

// ---------- HTTP 공통 ----------

func (s *server) originAllowed(o string) bool {
	for _, a := range s.cfg.AllowedOrigins {
		if strings.TrimSpace(a) == o {
			return true
		}
	}
	return false
}

func (s *server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); o != "" && s.originAllowed(o) {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", o)
			h.Set("Vary", "Origin")
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			// Chrome Local Network Access: 공개 https 페이지 → localhost 요청의 preflight 에 필요
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

func (s *server) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+s.cfg.Token {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		h(w, r)
	}
}

func method(m string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != m {
			w.Header().Set("Allow", m)
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
			return
		}
		h(w, r)
	}
}

func get(h http.HandlerFunc) http.HandlerFunc  { return method(http.MethodGet, h) }
func post(h http.HandlerFunc) http.HandlerFunc { return method(http.MethodPost, h) }

// exclusive 는 환경을 바꾸는 작업이 이미 돌고 있으면 409 로 돌려보낸다.
func (s *server) exclusive(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.envMu.TryLock() {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "another environment operation is in progress"})
			return
		}
		defer s.envMu.Unlock()
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

// 요청 본문 상한 — 검사 50개 + 스크립트 20개 × 64KiB 가 넉넉히 들어간다.
const maxRequestBytes = 4 << 20

func readJSON(r *http.Request, v any) error {
	if r.Body == nil || r.ContentLength == 0 {
		return nil
	}
	return json.NewDecoder(http.MaxBytesReader(nil, r.Body, maxRequestBytes)).Decode(v)
}

// writeWorkstationFile 은 본문을 workstation 의 경로에 쓴다(상위 디렉터리를 만들고, 필요하면 실행 권한).
// kubeconfig 주입과 보조 스크립트 설치가 같은 길을 쓴다.
func (s *server) writeWorkstationFile(ctx context.Context, path, body string, executable bool) error {
	dir := path[:strings.LastIndexByte(path, '/')]
	script := fmt.Sprintf("mkdir -p %s && cat > %s", dir, path)
	if executable {
		script += " && chmod +x " + path
	}
	_, err := runInput(ctx, s.runner, body, "docker", "exec", "-i", s.cfg.Workstation, "sh", "-c", script)
	return err
}

// ---------- docker 조회 ----------

// containerState 는 running / exited 같은 docker 상태를, 컨테이너가 없으면 "missing" 을 돌려준다.
func (s *server) containerState(ctx context.Context, name string) string {
	out, err := run(ctx, s.runner, "docker", "inspect", "-f", "{{.State.Status}}", name)
	if err != nil || out == "" {
		return "missing"
	}
	return out
}

func (s *server) kindNodes(ctx context.Context) []string {
	out, _ := run(ctx, s.runner, "docker", "ps", "--filter", "label=io.x-k8s.kind.cluster="+s.cfg.KindCluster, "--format", "{{.Names}}")
	nodes := strings.Fields(out)
	if nodes == nil {
		nodes = []string{}
	}
	return nodes
}

// ---------- 단계 기록 ----------

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

// handleStatus 는 네 가지 docker 조회를 병렬로 한다 — 대시보드가 자주 폴링한다.
func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var (
		wg                   sync.WaitGroup
		dockerVer, dockerErr string
		workstation, floci   string
		nodes                []string
	)
	wg.Add(4)
	go func() {
		defer wg.Done()
		out, err := run(ctx, s.runner, "docker", "version", "--format", "{{.Server.Version}}")
		if err != nil {
			dockerErr = firstLine(out)
			if dockerErr == "" {
				dockerErr = err.Error()
			}
			return
		}
		dockerVer = out
	}()
	go func() { defer wg.Done(); workstation = s.containerState(ctx, s.cfg.Workstation) }()
	go func() { defer wg.Done(); floci = s.containerState(ctx, s.cfg.Floci) }()
	go func() { defer wg.Done(); nodes = s.kindNodes(ctx) }()
	wg.Wait()
	body := map[string]any{
		"version":       version,
		"docker_server": dockerVer,
		"workstation":   workstation,
		"floci":         floci,
		"kind_nodes":    nodes,
	}
	if dockerErr != "" {
		body["docker_error"] = dockerErr
	}
	writeJSON(w, 200, body)
}
