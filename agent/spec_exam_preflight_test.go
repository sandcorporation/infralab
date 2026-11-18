package main

// target: agent/spec_exam_preflight_test.go
// AC: #78: GET /api/preflight(에이전트 토큰 필요, 없으면 401)가 engine·linux_mode·permission 세 항목을 이 순서로 주고, 모두 통과면 ok: true
// AC: #78: 엔진이 꺼져 있으면(docker version 실패) engine 실패 + 안내 링크, ok: false
// AC: #78: docker 가 Windows 컨테이너 모드면(docker info 의 OSType 이 linux 가 아님) linux_mode 실패
// AC: #78: docker 소켓 권한 오류(permission denied)면 permission 실패
//
// 응시 전 점검을 HTTP 핸들러(newHandler)와 가짜 runner(fakeRunner)로 본다. docker 는 외부 프로세스라
// 응답을 명령 접두로 꾸민다: 엔진은 `docker version`, 컨테이너 모드는 `docker info` 의 OSType(stdout 에
// OSType 값 한 줄, 예: `docker info --format {{.OSType}}`). 진짜 Docker 는 쓰지 않는다.

import (
	"net/http"
	"testing"
)

type preflightResponse struct {
	OK     bool `json:"ok"`
	Checks []struct {
		ID      string `json:"id"`
		OK      bool   `json:"ok"`
		Message string `json:"message"`
		HelpURL string `json:"help_url"`
	} `json:"checks"`
}

func preflight(t *testing.T, fake *fakeRunner) preflightResponse {
	t.Helper()
	srv := newTestServer(t, fake)
	res := do(t, srv, "GET", "/api/preflight", "", authed(nil))
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var body preflightResponse
	decode(t, res, &body)
	if len(body.Checks) != 3 {
		t.Fatalf("checks = %+v, want 3 items", body.Checks)
	}
	want := []string{"engine", "linux_mode", "permission"}
	for i, c := range body.Checks {
		if c.ID != want[i] {
			t.Fatalf("checks[%d].id = %q, want %q (order engine, linux_mode, permission)", i, c.ID, want[i])
		}
	}
	return body
}

func checkByID(t *testing.T, body preflightResponse, id string) (ok bool, message, helpURL string) {
	t.Helper()
	for _, c := range body.Checks {
		if c.ID == id {
			return c.OK, c.Message, c.HelpURL
		}
	}
	t.Fatalf("no check %q in %+v", id, body.Checks)
	return false, "", ""
}

func healthyDocker() *fakeRunner {
	fake := newFakeRunner()
	fake.respond("docker version", "27.3.1\n", 0)
	fake.respond("docker info", "linux\n", 0)
	return fake
}

func TestSpecExamPreflight_WithoutTokenIs401(t *testing.T) {
	t.Skip("#78")
	srv := newTestServer(t, healthyDocker())
	res := do(t, srv, "GET", "/api/preflight", "", nil)
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", res.StatusCode)
	}
	res = do(t, srv, "GET", "/api/preflight", "", map[string]string{"Authorization": "Bearer wrong"})
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status with wrong token = %d, want 401", res.StatusCode)
	}
}

func TestSpecExamPreflight_AllPassIsOK(t *testing.T) {
	t.Skip("#78")
	body := preflight(t, healthyDocker())
	if !body.OK {
		t.Fatalf("ok = false, want true: %+v", body.Checks)
	}
	for _, c := range body.Checks {
		if !c.OK {
			t.Fatalf("check %s failed on a healthy docker: %+v", c.ID, c)
		}
	}
}

func TestSpecExamPreflight_EngineDownFailsEngineWithHelp(t *testing.T) {
	t.Skip("#78")
	fake := newFakeRunner()
	down := Result{
		Stderr:   "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
		ExitCode: 1,
	}
	fake.respondFull("docker version", down)
	fake.respondFull("docker info", down)

	body := preflight(t, fake)

	if body.OK {
		t.Fatal("ok = true with the engine down, want false")
	}
	ok, message, help := checkByID(t, body, "engine")
	if ok {
		t.Fatal("engine ok = true with the engine down")
	}
	if message == "" || help == "" {
		t.Fatalf("engine failure needs a message and a help link: message=%q help_url=%q", message, help)
	}
}

func TestSpecExamPreflight_WindowsContainersFailLinuxMode(t *testing.T) {
	t.Skip("#78")
	fake := newFakeRunner()
	fake.respond("docker version", "27.3.1\n", 0)
	fake.respond("docker info", "windows\n", 0)

	body := preflight(t, fake)

	if body.OK {
		t.Fatal("ok = true in Windows container mode, want false")
	}
	ok, message, help := checkByID(t, body, "linux_mode")
	if ok {
		t.Fatal("linux_mode ok = true in Windows container mode")
	}
	if message == "" || help == "" {
		t.Fatalf("linux_mode failure needs a message and a help link: message=%q help_url=%q", message, help)
	}
	if engineOK, _, _ := checkByID(t, body, "engine"); !engineOK {
		t.Fatal("engine ok = false although docker version answered")
	}
	if permOK, _, _ := checkByID(t, body, "permission"); !permOK {
		t.Fatal("permission ok = false although docker answered")
	}
}

func TestSpecExamPreflight_PermissionDeniedFailsPermission(t *testing.T) {
	t.Skip("#78")
	fake := newFakeRunner()
	denied := Result{
		Stderr:   "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.47/version\": dial unix /var/run/docker.sock: connect: permission denied",
		ExitCode: 1,
	}
	fake.respondFull("docker version", denied)
	fake.respondFull("docker info", denied)

	body := preflight(t, fake)

	if body.OK {
		t.Fatal("ok = true with permission denied, want false")
	}
	ok, message, help := checkByID(t, body, "permission")
	if ok {
		t.Fatal("permission ok = true with permission denied")
	}
	if message == "" || help == "" {
		t.Fatalf("permission failure needs a message and a help link: message=%q help_url=%q", message, help)
	}
}
