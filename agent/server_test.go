package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 시험의 이음새는 HTTP 응답과 runner 에 넘어간 명령 인자다. docker·kind 는 외부 프로세스라
// 가짜 runner 로 바꿔 끼운다 — Docker 없이 돈다.

const testToken = "t0k3n"

func newTestServer(t *testing.T, fake *fakeRunner) *httptest.Server {
	t.Helper()
	cfg := config{
		Token:          testToken,
		AllowedOrigins: []string{"https://lab.example.com"},
		Workstation:    "infralab-workstation",
		Floci:          "infralab-floci",
		KindCluster:    "infralab",
	}
	srv := httptest.NewServer(newHandler(cfg, fake))
	t.Cleanup(srv.Close)
	return srv
}

func do(t *testing.T, srv *httptest.Server, method, path, body string, headers map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func authed(extra map[string]string) map[string]string {
	h := map[string]string{"Authorization": "Bearer " + testToken}
	for k, v := range extra {
		h[k] = v
	}
	return h
}

func decode(t *testing.T, res *http.Response, v any) {
	t.Helper()
	defer res.Body.Close()
	if err := json.NewDecoder(res.Body).Decode(v); err != nil {
		t.Fatalf("decode: %v", err)
	}
}

func TestStatus_WithoutTokenIsUnauthorized(t *testing.T) {
	srv := newTestServer(t, newFakeRunner())
	res := do(t, srv, "GET", "/api/status", "", nil)
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", res.StatusCode)
	}
	res = do(t, srv, "GET", "/api/status", "", map[string]string{"Authorization": "Bearer wrong"})
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status with wrong token = %d, want 401", res.StatusCode)
	}
}

func TestCORS_AllowedOriginGetsPrivateNetworkHeaders(t *testing.T) {
	srv := newTestServer(t, newFakeRunner())
	res := do(t, srv, "GET", "/api/status", "", authed(map[string]string{"Origin": "https://lab.example.com"}))
	if got := res.Header.Get("Access-Control-Allow-Origin"); got != "https://lab.example.com" {
		t.Fatalf("Allow-Origin = %q", got)
	}
	if got := res.Header.Get("Access-Control-Allow-Private-Network"); got != "true" {
		t.Fatalf("Allow-Private-Network = %q, want true", got)
	}
}

func TestCORS_OtherOriginGetsNoHeaders(t *testing.T) {
	srv := newTestServer(t, newFakeRunner())
	res := do(t, srv, "GET", "/api/status", "", authed(map[string]string{"Origin": "https://evil.example.com"}))
	if got := res.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("Allow-Origin = %q, want empty", got)
	}
	if got := res.Header.Get("Access-Control-Allow-Private-Network"); got != "" {
		t.Fatalf("Allow-Private-Network = %q, want empty", got)
	}
}

func TestCORS_PreflightSucceedsWithoutToken(t *testing.T) {
	srv := newTestServer(t, newFakeRunner())
	res := do(t, srv, "OPTIONS", "/api/status", "", map[string]string{
		"Origin":                        "https://lab.example.com",
		"Access-Control-Request-Method": "GET",
	})
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight status = %d, want 204", res.StatusCode)
	}
	if got := res.Header.Get("Access-Control-Allow-Headers"); !strings.Contains(got, "Authorization") {
		t.Fatalf("Allow-Headers = %q, want Authorization", got)
	}
}

func TestStatus_ReportsVersionDockerContainersAndKindNodes(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("docker version --format {{.Server.Version}}", "29.6.2", 0)
	fake.respond("docker inspect -f {{.State.Status}} infralab-workstation", "running", 0)
	fake.respond("docker inspect -f {{.State.Status}} infralab-floci", "exited", 0)
	fake.respond("docker ps --filter label=io.x-k8s.kind.cluster=infralab --format {{.Names}}",
		"infralab-control-plane\ninfralab-worker\ninfralab-worker2", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/status", "", authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got struct {
		Version      string   `json:"version"`
		DockerServer string   `json:"docker_server"`
		Workstation  string   `json:"workstation"`
		Floci        string   `json:"floci"`
		KindNodes    []string `json:"kind_nodes"`
	}
	decode(t, res, &got)
	if got.Version != version {
		t.Errorf("version = %q, want %q", got.Version, version)
	}
	if got.DockerServer != "29.6.2" {
		t.Errorf("docker_server = %q", got.DockerServer)
	}
	if got.Workstation != "running" || got.Floci != "exited" {
		t.Errorf("workstation=%q floci=%q", got.Workstation, got.Floci)
	}
	if len(got.KindNodes) != 3 || got.KindNodes[0] != "infralab-control-plane" {
		t.Errorf("kind_nodes = %v", got.KindNodes)
	}
}

func TestStatus_MissingContainerIsReportedAsMissing(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("docker inspect -f {{.State.Status}} infralab-floci", "Error: No such object: infralab-floci", 1)
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/status", "", authed(nil))
	var got struct {
		Floci     string   `json:"floci"`
		KindNodes []string `json:"kind_nodes"`
	}
	decode(t, res, &got)
	if got.Floci != "missing" {
		t.Errorf("floci = %q, want missing", got.Floci)
	}
	if got.KindNodes == nil || len(got.KindNodes) != 0 {
		t.Errorf("kind_nodes = %#v, want empty list (not null)", got.KindNodes)
	}
}

func TestStatus_DockerDaemonDownIsReportedAsDockerError(t *testing.T) {
	fake := newFakeRunner()
	fake.respondFull("docker version", Result{Stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?", ExitCode: 1})
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/status", "", authed(nil))
	var got struct {
		DockerServer string `json:"docker_server"`
		DockerError  string `json:"docker_error"`
	}
	decode(t, res, &got)
	if got.DockerServer != "" {
		t.Errorf("docker_server = %q, want empty when the daemon is down", got.DockerServer)
	}
	if !strings.Contains(got.DockerError, "Cannot connect to the Docker daemon") {
		t.Errorf("docker_error = %q", got.DockerError)
	}
}

func TestMutatingEndpointsRejectGet(t *testing.T) {
	fake := newFakeRunner()
	srv := newTestServer(t, fake)
	for _, p := range []string{"/api/kind/up", "/api/kind/down"} {
		res := do(t, srv, "GET", p, "", authed(nil))
		if res.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("GET %s = %d, want 405", p, res.StatusCode)
		}
	}
	if n := len(fake.callsWithPrefix("kind")); n != 0 {
		t.Errorf("GET ran %d kind commands, want 0", n)
	}
}
