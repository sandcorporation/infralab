package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// ---------- 평가는 순수 함수 — docker 없이 표로 시험한다 ----------

func TestEvaluate_ExpectKinds(t *testing.T) {
	cases := []struct {
		name   string
		expect string
		res    Result
		pass   bool
	}{
		{"exit_zero passes on 0", `{"type":"exit_zero"}`, Result{ExitCode: 0}, true},
		{"exit_zero fails on 1", `{"type":"exit_zero"}`, Result{ExitCode: 1, Stderr: "no such bucket"}, false},
		{"equals trims", `{"type":"equals","value":"Enabled"}`, Result{Stdout: "Enabled\n"}, true},
		{"equals is exact", `{"type":"equals","value":"Enabled"}`, Result{Stdout: "Suspended\n"}, false},
		{"equals ignores stderr", `{"type":"equals","value":"Enabled"}`, Result{Stdout: "Enabled\n", Stderr: "warning"}, true},
		{"contains", `{"type":"contains","value":"Ready"}`, Result{Stdout: "node1   Ready   control-plane\n"}, true},
		{"contains is a substring check", `{"type":"contains","value":"Ready"}`, Result{Stdout: "node1   NotReady\n"}, true},
		{"contains misses when absent", `{"type":"contains","value":"Ready"}`, Result{Stdout: "node1   Unknown\n"}, false},
		{"regex", `{"type":"regex","pattern":"^v1\\.[0-9]+"}`, Result{Stdout: "v1.31.0\n"}, true},
		{"regex misses", `{"type":"regex","pattern":"^v2"}`, Result{Stdout: "v1.31.0\n"}, false},
		{"jsonpath equals", `{"type":"jsonpath","path":".spec.type","equals":"ClusterIP"}`, Result{Stdout: `{"spec":{"type":"ClusterIP"}}`}, true},
		{"jsonpath equals number as text", `{"type":"jsonpath","path":".status.readyReplicas","equals":"2"}`, Result{Stdout: `{"status":{"readyReplicas":2}}`}, true},
		{"jsonpath min", `{"type":"jsonpath","path":".status.readyReplicas","min":2}`, Result{Stdout: `{"status":{"readyReplicas":3}}`}, true},
		{"jsonpath min fails below", `{"type":"jsonpath","path":".status.readyReplicas","min":2}`, Result{Stdout: `{"status":{"readyReplicas":1}}`}, false},
		{"jsonpath index", `{"type":"jsonpath","path":".items[1].metadata.name","equals":"worker"}`, Result{Stdout: `{"items":[{"metadata":{"name":"cp"}},{"metadata":{"name":"worker"}}]}`}, true},
		{"jsonpath contains in array", `{"type":"jsonpath","path":".Buckets","contains":"lab-site"}`, Result{Stdout: `{"Buckets":["a","lab-site"]}`}, true},
		{"jsonpath contains in string", `{"type":"jsonpath","path":".msg","contains":"ok"}`, Result{Stdout: `{"msg":"all ok here"}`}, true},
		{"jsonpath missing path fails", `{"type":"jsonpath","path":".nope","min":1}`, Result{Stdout: `{"a":1}`}, false},
		{"jsonpath non-json fails", `{"type":"jsonpath","path":".a","min":1}`, Result{Stdout: `error: not found`}, false},
		{"jsonpath two documents fail", `{"type":"jsonpath","path":".a","min":1}`, Result{Stdout: "{\"a\":1}\n{\"a\":2}\n"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, err := parseExpect(json.RawMessage(c.expect))
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			pass, _ := evaluate(e, c.res)
			if pass != c.pass {
				t.Errorf("pass=%v, want %v", pass, c.pass)
			}
		})
	}
}

func TestParseExpect_RejectsBadDefinitions(t *testing.T) {
	bad := []string{
		`{"type":"always"}`,
		`{"type":"equals"}`,
		`{"type":"regex","pattern":"("}`,
		`{"type":"jsonpath","path":"status.ready","min":1}`,
		`{"type":"jsonpath","path":".a","min":1,"equals":"x"}`,
		`{"type":"jsonpath","path":".a"}`,
		`{"type":"jsonpath","path":".a[x]","min":1}`,
		``,
	}
	for _, b := range bad {
		if _, err := parseExpect(json.RawMessage(b)); err == nil {
			t.Errorf("%s: expected an error", b)
		}
	}
}

// ---------- HTTP 표면 + 가짜 runner ----------

type checkResponse struct {
	AgentVersion string        `json:"agent_version"`
	Passed       int           `json:"passed"`
	Total        int           `json:"total"`
	Results      []checkResult `json:"results"`
}

const (
	runPrefix     = "docker exec -w /work -e INFRALAB_CMD="
	installPrefix = "docker exec -i infralab-workstation sh -c mkdir -p /opt/infralab/checks/"
)

func withRunningWorkstation(fake *fakeRunner) *fakeRunner {
	fake.respond("docker inspect -f {{.State.Status}} infralab-workstation", "running", 0)
	return fake
}

const s3Checks = `{"checks":[
  {"id":"bucket-exists","name":"버킷","hint":"aws s3 mb","command":"aws s3api head-bucket --bucket lab-site","timeout_seconds":30,"expect":{"type":"exit_zero"}},
  {"id":"versioning","name":"버저닝","hint":"","command":"aws s3api get-bucket-versioning --bucket lab-site --query Status --output text","timeout_seconds":30,"expect":{"type":"equals","value":"Enabled"}}
]}`

func TestCheck_RunsEachCommandInWorkstationAndReportsResults(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respondFull(runPrefix+"aws s3api head-bucket",
		Result{Stderr: "An error occurred (404) when calling the HeadBucket operation: Not Found", ExitCode: 254})
	fake.respond(runPrefix+"aws s3api get-bucket-versioning", "Enabled\n", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/check", s3Checks, authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got checkResponse
	decode(t, res, &got)
	if got.Total != 2 || got.Passed != 1 || got.AgentVersion != version {
		t.Fatalf("summary = %+v", got)
	}
	first, second := got.Results[0], got.Results[1]
	if first.ID != "bucket-exists" || first.Pass || first.ExitCode != 254 || !strings.Contains(first.Output, "HeadBucket") {
		t.Errorf("first = %+v", first)
	}
	if first.Error != "" {
		t.Errorf("a wrong answer is not an error: %+v", first)
	}
	if first.Hint != "aws s3 mb" || first.Name != "버킷" {
		t.Errorf("hint/name not echoed: %+v", first)
	}
	if second.ID != "versioning" || !second.Pass || strings.TrimSpace(second.Output) != "Enabled" {
		t.Errorf("second = %+v", second)
	}
	runs := fake.callsWithPrefix(runPrefix)
	if len(runs) != 2 {
		t.Fatalf("commands run = %d, want 2", len(runs))
	}
	// 작업 폴더 /work 의 비로그인 bash 에서, 안쪽 timeout 으로 감싸서 돈다.
	s := runs[0].String()
	if !strings.Contains(s, " infralab-workstation bash -c export PATH=/opt/infralab/checks/") ||
		!strings.Contains(s, `timeout 30 bash -c "$INFRALAB_CMD"`) || strings.Contains(s, "bash -lc") {
		t.Errorf("run command = %q", s)
	}
}

func TestCheck_WorkstationDownIs503NotAllFail(t *testing.T) {
	fake := newFakeRunner()
	fake.respond("docker inspect -f {{.State.Status}} infralab-workstation", "Error: No such object", 1)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/check", s3Checks, authed(nil))
	if res.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", res.StatusCode)
	}
	if n := len(fake.callsWithPrefix(runPrefix)); n != 0 {
		t.Errorf("ran %d checks against a missing workstation", n)
	}
}

func TestCheck_DockerLevelFailureIsAnErrorNotAWrongAnswer(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respondFull(runPrefix, Result{Stderr: "Error response from daemon: container abc is not running", ExitCode: 126})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/check", `{"checks":[{"id":"a","name":"a","command":"true","expect":{"type":"exit_zero"}}]}`, authed(nil))
	var got checkResponse
	decode(t, res, &got)
	r := got.Results[0]
	if r.Pass || !strings.HasPrefix(r.Error, "workstation unavailable") {
		t.Errorf("result = %+v", r)
	}
}

func TestCheck_OutputIsClippedAndMarkedTruncated(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respond(runPrefix, strings.Repeat("x", 20000), 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/check", `{"checks":[{"id":"big","name":"b","command":"cat big","expect":{"type":"exit_zero"}}]}`, authed(nil))
	var got checkResponse
	decode(t, res, &got)
	r := got.Results[0]
	if !r.Truncated || len(r.Output) > maxOutputBytes+64 || !strings.HasSuffix(r.Output, "…(truncated)") {
		t.Errorf("truncated=%v len=%d", r.Truncated, len(r.Output))
	}
	if !r.Pass {
		t.Error("truncation must not change the verdict")
	}
}

func TestCheck_TimeoutFailsThatCheckAndContinues(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.onCall = func(c call) {
		if strings.Contains(c.String(), "sleep 999") {
			time.Sleep(3500 * time.Millisecond) // 안쪽 timeout(1s) + 여유(2s) 를 넘긴다
		}
	}
	fake.respond(runPrefix+"echo after", "after\n", 0)
	srv := newTestServer(t, fake)

	body := `{"checks":[
	  {"id":"slow","name":"s","command":"sleep 999","timeout_seconds":1,"expect":{"type":"exit_zero"}},
	  {"id":"next","name":"n","command":"echo after","expect":{"type":"equals","value":"after"}}]}`
	res := do(t, srv, "POST", "/api/check", body, authed(nil))
	var got checkResponse
	decode(t, res, &got)
	if len(got.Results) != 2 {
		t.Fatalf("results = %d", len(got.Results))
	}
	if got.Results[0].Pass || !strings.Contains(got.Results[0].Error, "timed out") {
		t.Errorf("slow = %+v", got.Results[0])
	}
	if !got.Results[1].Pass {
		t.Errorf("next did not run after the timeout: %+v", got.Results[1])
	}
}

func TestCheck_InnerTimeoutExitCodeIsReportedAsTimeout(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respondFull(runPrefix, Result{ExitCode: 124})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/check", `{"checks":[{"id":"a","name":"a","command":"sleep 99","timeout_seconds":5,"expect":{"type":"exit_zero"}}]}`, authed(nil))
	var got checkResponse
	decode(t, res, &got)
	if got.Results[0].Pass || !strings.Contains(got.Results[0].Error, "timed out after 5s") {
		t.Errorf("result = %+v", got.Results[0])
	}
}

func TestCheck_BadDefinitionIs400AndRunsNothing(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	srv := newTestServer(t, fake)
	bodies := []string{
		`{"checks":[]}`,
		`{"checks":[{"id":"a","command":"true","expect":{"type":"magic"}}]}`,
		`{"checks":[{"id":"a","command":"true","expect":{"type":"exit_zero"}},{"id":"b","command":"true","expect":{"type":"regex","pattern":"("}}]}`,
		`{"checks":[{"id":"","command":"true","expect":{"type":"exit_zero"}}]}`,
		`{"checks":[{"id":"a","command":"true","expect":{"type":"exit_zero"}}],"scripts":{"../evil.sh":"x"}}`,
		`not json`,
	}
	for _, b := range bodies {
		res := do(t, srv, "POST", "/api/check", b, authed(nil))
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s → %d, want 400", b, res.StatusCode)
		}
	}
	if n := len(fake.callsWithPrefix("docker exec")); n != 0 {
		t.Errorf("rejected requests ran %d docker exec commands", n)
	}
}

func TestCheck_ScriptsAreInstalledPerRequestThenRemoved(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	srv := newTestServer(t, fake)
	body := `{"checks":[{"id":"nginx","name":"n","command":"check-nginx.sh","expect":{"type":"exit_zero"}}],
	          "scripts":{"check-nginx.sh":"#!/bin/sh\ncurl -sf http://10.0.0.5/\n"}}`
	res := do(t, srv, "POST", "/api/check", body, authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	installs := fake.callsWithPrefix(installPrefix)
	if len(installs) != 1 || !strings.Contains(installs[0].Stdin, "curl -sf") || !strings.Contains(installs[0].String(), "check-nginx.sh && chmod +x") {
		t.Fatalf("install calls = %+v", installs)
	}
	runs := fake.callsWithPrefix(runPrefix)
	if len(runs) != 1 {
		t.Fatalf("run calls = %+v", runs)
	}
	// 설치된 디렉터리가 그 요청의 PATH 에 있고, 끝나면 지워진다.
	dir := strings.TrimPrefix(installs[0].String(), installPrefix)
	dir = "/opt/infralab/checks/" + dir[:strings.IndexByte(dir, ' ')]
	if !strings.Contains(runs[0].String(), "PATH="+dir+":$PATH") {
		t.Errorf("run did not use the request's script dir %s: %q", dir, runs[0].String())
	}
	removes := fake.callsWithPrefix("docker exec infralab-workstation rm -rf " + dir)
	if len(removes) != 1 {
		t.Errorf("script dir was not removed: %+v", fake.calls)
	}
	// 순서: 설치 → 실행 → 제거
	order := []string{}
	for _, c := range fake.calls {
		s := c.String()
		switch {
		case strings.HasPrefix(s, installPrefix):
			order = append(order, "install")
		case strings.HasPrefix(s, runPrefix):
			order = append(order, "run")
		case strings.Contains(s, "rm -rf"):
			order = append(order, "remove")
		}
	}
	if strings.Join(order, ",") != "install,run,remove" {
		t.Errorf("order = %v", order)
	}
}

func TestCheck_RequiresTokenAndPost(t *testing.T) {
	srv := newTestServer(t, withRunningWorkstation(newFakeRunner()))
	if res := do(t, srv, "POST", "/api/check", s3Checks, nil); res.StatusCode != 401 {
		t.Errorf("no token → %d", res.StatusCode)
	}
	if res := do(t, srv, "GET", "/api/check", "", authed(nil)); res.StatusCode != 405 {
		t.Errorf("GET → %d", res.StatusCode)
	}
}

func TestCheck_IsRefusedWhileEnvironmentIsChanging(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
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
	<-started
	if res := do(t, srv, "POST", "/api/check", s3Checks, authed(nil)); res.StatusCode != http.StatusConflict {
		t.Errorf("check during kind up = %d, want 409", res.StatusCode)
	}
	close(release)
	<-first
}

func TestCheck_OversizedBodyIsRejected(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	srv := newTestServer(t, fake)
	huge := `{"checks":[{"id":"a","command":"` + strings.Repeat("x", maxRequestBytes+1024) + `","expect":{"type":"exit_zero"}}]}`
	if res := do(t, srv, "POST", "/api/check", huge, authed(nil)); res.StatusCode != http.StatusBadRequest {
		t.Errorf("oversized body → %d, want 400", res.StatusCode)
	}
}
