package main

import (
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"
)

type setupResponse struct {
	OK    bool   `json:"ok"`
	Steps []step `json:"steps"`
}

const (
	rulesWritePrefix = "docker exec -i infralab-workstation sh -c mkdir -p /work && cat > /work/"
	markWritePrefix  = "docker exec -i infralab-workstation sh -c mkdir -p /root/.infralab && cat > /root/.infralab/"
)

func setupFake() *fakeRunner {
	fake := withRunningWorkstation(flociFake())
	fake.respond("kind get clusters", "", 0)
	fake.respond("kind get kubeconfig --name infralab --internal", "apiVersion: v1\nkind: Config\n", 0)
	return fake
}

func indexOf(fake *fakeRunner, prefix string) int {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	for i, c := range fake.calls {
		if strings.HasPrefix(c.String(), prefix) {
			return i
		}
	}
	return -1
}

const fullSetup = `{
  "scenario_id": "web-down",
  "reset": {"floci": true, "kind": {"control_planes": 1, "workers": 2}},
  "setup": {"command": "break-it.sh", "scripts": {"break-it.sh": "kubectl scale deploy web --replicas=0\n"}, "timeout_seconds": 90},
  "ai_rules": "# 규칙\n80 포트 금지\n"
}`

func stepNames(steps []step) []string {
	var names []string
	for _, s := range steps {
		names = append(names, s.Name)
	}
	return names
}

func TestSetup_RunsResetRulesMarkAndSetupInOrder(t *testing.T) {
	fake := setupFake()
	srv := newTestServer(t, fake)

	before := time.Now().UTC().Add(-2 * time.Second)
	res := do(t, srv, "POST", "/api/setup", fullSetup, authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got setupResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}

	// 단계 이름의 순서: floci/* → kind/* → rules → mark → setup
	order := ""
	for _, n := range stepNames(got.Steps) {
		switch {
		case strings.HasPrefix(n, "floci/") && !strings.HasSuffix(order, "floci,"):
			order += "floci,"
		case strings.HasPrefix(n, "kind/") && !strings.HasSuffix(order, "kind,"):
			order += "kind,"
		case n == "rules" || n == "mark" || n == "setup":
			order += n + ","
		}
	}
	if order != "floci,kind,rules,setup,mark," {
		t.Fatalf("step order = %s (steps %v)", order, stepNames(got.Steps))
	}

	// runner 에 넘어간 호출의 순서도 같다.
	idx := []int{
		indexOf(fake, "docker run -d --name infralab-floci"),
		indexOf(fake, "kind create cluster"),
		indexOf(fake, rulesWritePrefix+"CLAUDE.md"),
		indexOf(fake, rulesWritePrefix+"AGENTS.md"),
		indexOf(fake, runPrefix),
		indexOf(fake, markWritePrefix+"web-down.prepared"),
	}
	for i, v := range idx {
		if v < 0 || (i > 0 && v < idx[i-1]) {
			t.Fatalf("call order = %v", idx)
		}
	}

	// 규칙 파일 두 개는 같은 본문이다.
	claude := fake.callsWithPrefix(rulesWritePrefix + "CLAUDE.md")
	agents := fake.callsWithPrefix(rulesWritePrefix + "AGENTS.md")
	if len(claude) != 1 || len(agents) != 1 || claude[0].Stdin != "# 규칙\n80 포트 금지\n" || agents[0].Stdin != claude[0].Stdin {
		t.Errorf("rules writes: claude=%+v agents=%+v", claude, agents)
	}
	// 준비 표시: 홈 볼륨의 ~/.infralab/<scenario_id>.prepared 에 UTC 시각.
	marks := fake.callsWithPrefix(markWritePrefix + "web-down.prepared")
	if len(marks) != 1 {
		t.Fatalf("mark writes = %+v", marks)
	}
	stamp := strings.TrimSpace(marks[0].Stdin)
	if !regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`).MatchString(stamp) {
		t.Fatalf("mark stdin = %q, want RFC3339 UTC", marks[0].Stdin)
	}
	when, _ := time.Parse(time.RFC3339, stamp)
	if when.Before(before.Truncate(time.Second)) || when.After(time.Now().UTC().Add(2*time.Second)) {
		t.Errorf("mark time %s is not now", stamp)
	}
}

func TestSetup_ScriptsAreInstalledRunWithTheirTimeoutAndRemoved(t *testing.T) {
	fake := setupFake()
	srv := newTestServer(t, fake)
	res := do(t, srv, "POST", "/api/setup", fullSetup, authed(nil))
	var got setupResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("steps=%+v", got.Steps)
	}
	installs := fake.callsWithPrefix(installPrefix)
	if len(installs) != 1 || !strings.Contains(installs[0].Stdin, "replicas=0") || !strings.Contains(installs[0].String(), "break-it.sh && chmod +x") {
		t.Fatalf("installs = %+v", installs)
	}
	runs := fake.callsWithPrefix(runPrefix)
	if len(runs) != 1 {
		t.Fatalf("runs = %+v", runs)
	}
	s := runs[0].String()
	if !strings.Contains(s, "INFRALAB_CMD=break-it.sh") || !strings.Contains(s, `timeout 90 bash -c "$INFRALAB_CMD"`) {
		t.Errorf("setup run = %q", s)
	}
	if n := len(fake.callsWithPrefix("docker exec infralab-workstation rm -rf /opt/infralab/checks/")); n != 1 {
		t.Errorf("script dir removals = %d, want 1", n)
	}
}

func TestSetup_KindIsRecreatedEvenWhenTheClusterAlreadyMatches(t *testing.T) {
	fake := setupFake()
	fake.respond("kind get clusters", "infralab", 0)
	fake.respond("docker ps --filter label=io.x-k8s.kind.cluster=infralab", threeNodes, 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/setup", `{"scenario_id":"k","reset":{"kind":{"control_planes":1,"workers":2}},"ai_rules":"r"}`, authed(nil))
	var got setupResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("steps=%+v", got.Steps)
	}
	del, create := indexOf(fake, "kind delete cluster --name infralab"), indexOf(fake, "kind create cluster")
	if del < 0 || create < 0 || del > create {
		t.Errorf("delete=%d create=%d, want delete before create", del, create)
	}
	if n := len(fake.callsWithPrefix("docker run -d --name infralab-floci")); n != 0 {
		t.Errorf("floci was reset although reset.floci is false")
	}
}

func TestSetup_FailingSetupIsNotOkAndKeepsItsOutput(t *testing.T) {
	fake := setupFake()
	fake.respondFull(runPrefix, Result{Stdout: "partial\n", Stderr: "kubectl: connection refused", ExitCode: 3})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/setup", fullSetup, authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got setupResponse
	decode(t, res, &got)
	if got.OK {
		t.Fatal("ok=true, want false")
	}
	last := got.Steps[len(got.Steps)-1]
	if last.Name != "setup" || !strings.Contains(last.Result, "connection refused") || !strings.Contains(last.Result, "partial") || !strings.Contains(last.Result, "ERROR") {
		t.Errorf("last step = %+v", last)
	}
	// 실패한 setup 은 준비 표시를 남기지 않고, 이전 준비의 표시도 먼저 지운다 — 채점이 열려 있으면 안 된다.
	if n := len(fake.callsWithPrefix(markWritePrefix)); n != 0 {
		t.Errorf("mark was written after a failed setup (%d writes)", n)
	}
	rm := indexOf(fake, "docker exec infralab-workstation rm -f /root/.infralab/web-down.prepared")
	if rm < 0 || rm > indexOf(fake, "docker run -d --name infralab-floci") {
		t.Errorf("old mark was not removed before the reset (rm at %d)", rm)
	}
}

func TestSetup_EarlierFailureSkipsEverythingAfterIt(t *testing.T) {
	fake := setupFake()
	fake.respond("docker inspect --format {{json .}} infralab-floci", "Error: No such object: infralab-floci", 1)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/setup", fullSetup, authed(nil))
	var got setupResponse
	decode(t, res, &got)
	if got.OK {
		t.Fatal("ok=true, want false")
	}
	for _, n := range []string{"kind create cluster", rulesWritePrefix, markWritePrefix, runPrefix} {
		if c := indexOf(fake, n); c >= 0 {
			t.Errorf("%q ran after the floci failure", n)
		}
	}
	for _, s := range got.Steps {
		if s.Name == "rules" || s.Name == "mark" || s.Name == "setup" {
			t.Errorf("step %s ran after a failure", s.Name)
		}
	}
}

func TestSetup_WithoutSetupAndResetOnlyRulesAndMarkAreWritten(t *testing.T) {
	fake := setupFake()
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/setup", `{"scenario_id":"plain-lab","reset":{"floci":false,"kind":null},"setup":null,"ai_rules":"규칙"}`, authed(nil))
	var got setupResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("steps=%+v", got.Steps)
	}
	if strings.Join(stepNames(got.Steps), ",") != "rules,mark" {
		t.Errorf("steps = %v, want rules,mark", stepNames(got.Steps))
	}
	for _, p := range []string{"kind ", "docker run", runPrefix, installPrefix} {
		if indexOf(fake, p) >= 0 {
			t.Errorf("unexpected call %q", p)
		}
	}
	if len(fake.callsWithPrefix(markWritePrefix+"plain-lab.prepared")) != 1 {
		t.Error("mark file was not written")
	}
}

func TestSetup_BadRequestsAreRejectedBeforeAnythingRuns(t *testing.T) {
	fake := setupFake()
	srv := newTestServer(t, fake)
	bad := []string{
		`{"scenario_id":"Bad_ID","ai_rules":"r"}`,
		`{"scenario_id":"../x","ai_rules":"r"}`,
		`{"scenario_id":"","ai_rules":"r"}`,
		`{"scenario_id":"a b","ai_rules":"r"}`,
		`{"scenario_id":"ok","reset":{"kind":{"control_planes":4,"workers":0}},"ai_rules":"r"}`,
		`{"scenario_id":"ok","reset":{"kind":{"control_planes":1,"workers":9}},"ai_rules":"r"}`,
		`{"scenario_id":"ok","setup":{"command":"  ","timeout_seconds":10},"ai_rules":"r"}`,
		`{"scenario_id":"ok","setup":{"command":"x","scripts":{"../evil.sh":"x"}},"ai_rules":"r"}`,
		`{"scenario_id":"ok","setup":{"command":"x","timeout_seconds":301},"ai_rules":"r"}`,
		`not json`,
	}
	for _, b := range bad {
		if res := do(t, srv, "POST", "/api/setup", b, authed(nil)); res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s → %d, want 400", b, res.StatusCode)
		}
	}
	if len(fake.calls) != 0 {
		t.Errorf("rejected requests ran %d commands: %v", len(fake.calls), fake.calls)
	}
}

func TestSetup_RequiresTokenAndPostAndARunningWorkstation(t *testing.T) {
	srv := newTestServer(t, setupFake())
	if res := do(t, srv, "POST", "/api/setup", fullSetup, nil); res.StatusCode != 401 {
		t.Errorf("no token → %d", res.StatusCode)
	}
	if res := do(t, srv, "GET", "/api/setup", "", authed(nil)); res.StatusCode != 405 {
		t.Errorf("GET → %d", res.StatusCode)
	}
	down := newFakeRunner()
	down.respond("docker inspect -f {{.State.Status}} infralab-workstation", "Error: No such object", 1)
	srv2 := newTestServer(t, down)
	if res := do(t, srv2, "POST", "/api/setup", fullSetup, authed(nil)); res.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("workstation down → %d, want 503", res.StatusCode)
	}
	if indexOf(down, "docker run") >= 0 || indexOf(down, "kind") >= 0 {
		t.Error("environment was touched although the workstation is down")
	}
}

func TestSetup_IsRefusedWhileEnvironmentIsChanging(t *testing.T) {
	fake := setupFake()
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
		t.Fatal("kind up never started")
	}
	if res := do(t, srv, "POST", "/api/setup", fullSetup, authed(nil)); res.StatusCode != http.StatusConflict {
		t.Errorf("setup during kind up = %d, want 409", res.StatusCode)
	}
	close(release)
	<-first
}
