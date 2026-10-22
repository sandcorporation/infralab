package main

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

type kindUpResponse struct {
	OK    bool   `json:"ok"`
	Steps []step `json:"steps"`
}

func TestKindUp_CreatesClusterWithRequestedNodesViaStdin(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "other-cluster", 0)
	fake.respond("kind get kubeconfig --name infralab --internal", "apiVersion: v1\nkind: Config\n", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{"control_planes":1,"workers":2}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	creates := fake.callsWithPrefix("kind create cluster --name infralab --config -")
	if len(creates) != 1 {
		t.Fatalf("kind create calls = %d, want 1", len(creates))
	}
	cfg := creates[0].Stdin
	if strings.Count(cfg, "role: control-plane") != 1 || strings.Count(cfg, "role: worker") != 2 {
		t.Errorf("kind config:\n%s", cfg)
	}
}

func TestKindUp_ExistingClusterOnlyReinjectsKubeconfig(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "infralab", 0)
	fake.respond("kind get kubeconfig --name infralab --internal", "apiVersion: v1\nclusters: [x]\n", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{"control_planes":1,"workers":2}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	if n := len(fake.callsWithPrefix("kind create")); n != 0 {
		t.Errorf("kind create calls = %d, want 0 (cluster exists)", n)
	}
	if got.Steps[0].Name != "create" || got.Steps[0].Result != "exists" {
		t.Errorf("first step = %+v, want create=exists", got.Steps[0])
	}
	writes := fake.callsWithPrefix("docker exec -i infralab-workstation sh -c mkdir -p /root/.kube && cat > /root/.kube/config")
	if len(writes) != 1 {
		t.Fatalf("kubeconfig writes = %d, want 1", len(writes))
	}
	if !strings.Contains(writes[0].Stdin, "clusters: [x]") {
		t.Errorf("kubeconfig stdin = %q", writes[0].Stdin)
	}
	if n := len(fake.callsWithPrefix("docker network connect kind infralab-workstation")); n != 1 {
		t.Errorf("network connect calls = %d, want 1", n)
	}
}

func TestKindUp_AlreadyConnectedNetworkIsNotAnError(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "infralab", 0)
	fake.respond("docker network connect kind infralab-workstation",
		"Error response from daemon: endpoint with name infralab-workstation already exists in network kind", 1)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
}

func TestKindUp_CreateFailureStopsAndReportsError(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "", 0)
	fake.respond("kind create cluster", "ERROR: failed to create cluster: node(s) already exist", 1)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{"workers":1}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if got.OK {
		t.Fatal("ok=true, want false")
	}
	if len(got.Steps) != 1 || !strings.Contains(got.Steps[0].Result, "ERROR") {
		t.Errorf("steps = %+v, want a single failed create step", got.Steps)
	}
	if n := len(fake.callsWithPrefix("docker exec -i infralab-workstation")); n != 0 {
		t.Errorf("kubeconfig was injected after a failed create")
	}
}

func TestKindDown_DeletesTheConfiguredCluster(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind delete cluster --name infralab", "Deleted nodes: [...]", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/down", "", authed(nil))
	var got struct {
		OK     bool   `json:"ok"`
		Output string `json:"output"`
	}
	decode(t, res, &got)
	if !got.OK || !strings.HasPrefix(got.Output, "Deleted nodes") {
		t.Errorf("got %+v", got)
	}
	if n := len(fake.callsWithPrefix("kind delete cluster --name infralab")); n != 1 {
		t.Errorf("delete calls = %d", n)
	}
}

func TestKindUp_StderrWarningsDoNotLeakIntoKubeconfig(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "infralab", 0)
	fake.respondFull("kind get kubeconfig --name infralab --internal", Result{
		Stdout: "apiVersion: v1\nkind: Config\n",
		Stderr: "WARNING: cgroup v1 detected\n",
	})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	writes := fake.callsWithPrefix("docker exec -i infralab-workstation sh -c")
	if len(writes) != 1 {
		t.Fatalf("kubeconfig writes = %d", len(writes))
	}
	if strings.Contains(writes[0].Stdin, "WARNING") {
		t.Errorf("stderr leaked into kubeconfig:\n%s", writes[0].Stdin)
	}
	if !strings.HasPrefix(writes[0].Stdin, "apiVersion: v1") {
		t.Errorf("kubeconfig stdin = %q", writes[0].Stdin)
	}
}

func TestKindUp_WorkstationAlreadyInKindNetworkIsNotReconnected(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "infralab", 0)
	fake.respond("docker network inspect kind -f", "infralab-control-plane infralab-workstation infralab-worker ", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/kind/up", `{}`, authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	if n := len(fake.callsWithPrefix("docker network connect")); n != 0 {
		t.Errorf("network connect calls = %d, want 0 (already a member)", n)
	}
}

func TestKindUp_TooManyNodesIsRejected(t *testing.T) {
	fake := newFakeRunner()
	srv := newTestServer(t, fake)
	for _, body := range []string{`{"workers":500}`, `{"control_planes":4}`, `{"workers":-1}`} {
		res := do(t, srv, "POST", "/api/kind/up", body, authed(nil))
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s → %d, want 400", body, res.StatusCode)
		}
	}
	if n := len(fake.callsWithPrefix("kind")); n != 0 {
		t.Errorf("rejected requests ran %d kind commands", n)
	}
}

func TestKindUp_ConcurrentRequestIsRefusedWhileOneRuns(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("kind get clusters", "", 0)
	release := make(chan struct{})
	started := make(chan struct{}, 1)
	fake.onCall = func(c call) {
		if strings.HasPrefix(c.String(), "kind create cluster") {
			started <- struct{}{}
			<-release
		}
	}
	srv := newTestServer(t, fake)

	first := make(chan *http.Response, 1)
	go func() { first <- do(t, srv, "POST", "/api/kind/up", `{"workers":1}`, authed(nil)) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("first request never reached kind create")
	}

	second := do(t, srv, "POST", "/api/kind/down", "", authed(nil))
	if second.StatusCode != http.StatusConflict {
		t.Errorf("second request = %d, want 409 while kind create is running", second.StatusCode)
	}
	close(release)
	if res := <-first; res.StatusCode != 200 {
		t.Errorf("first request = %d", res.StatusCode)
	}
	if n := len(fake.callsWithPrefix("kind create cluster")); n != 1 {
		t.Errorf("kind create ran %d times, want 1", n)
	}
	if n := len(fake.callsWithPrefix("kind delete")); n != 0 {
		t.Errorf("kind delete ran while create was in progress")
	}
}
