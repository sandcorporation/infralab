package main

import (
	"strings"
	"testing"
)

const flociInspect = `{
  "Config": {
    "Image": "floci/floci:2.3.0",
    "Entrypoint": ["/usr/local/bin/docker-entrypoint.sh"],
    "Cmd": ["/app/application", "-Dquarkus.http.host=0.0.0.0"],
    "Env": ["PATH=/usr/bin", "FLOCI_VERSION=2.3.0"],
    "Labels": {"com.docker.compose.project": "infralab", "com.docker.compose.service": "floci"}
  },
  "HostConfig": {
    "Binds": [],
    "Privileged": false,
    "RestartPolicy": {"Name": "unless-stopped"},
    "PortBindings": {"4566/tcp": [{"HostIp": "127.0.0.1", "HostPort": "4566"}]}
  },
  "Mounts": [
    {"Type": "bind", "Source": "/var/run/docker.sock", "Destination": "/var/run/docker.sock", "RW": true},
    {"Type": "volume", "Name": "infralab-floci-data", "Source": "/var/lib/docker/volumes/x/_data", "Destination": "/app/data", "RW": true},
    {"Type": "volume", "Name": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "Destination": "/tmp/anon", "RW": true}
  ],
  "NetworkSettings": {"Networks": {"infralab": {"Aliases": ["floci", "infralab-floci", "3f2a9c1d8e7b"]}}}
}`

func flociFake() *fakeRunner {
	fake := newFakeRunner()
	fake.respond("docker inspect --format {{json .}} infralab-floci", flociInspect, 0)
	fake.respond("docker run -d --name infralab-floci", "0123456789abcdef", 0)
	fake.respond("docker inspect -f {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} infralab-floci", "running healthy", 0)
	return fake
}

func TestFlociReset_RecreatesTheContainerWithTheSameConfig(t *testing.T) {
	fake := flociFake()
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/floci/reset", "", authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	if n := len(fake.callsWithPrefix("docker rm -f -v infralab-floci")); n != 1 {
		t.Errorf("rm -f -v calls = %d", n)
	}
	runs := fake.callsWithPrefix("docker run -d --name infralab-floci")
	if len(runs) != 1 {
		t.Fatalf("run calls = %d", len(runs))
	}
	cmd := runs[0].String()
	for _, want := range []string{
		"--restart unless-stopped",
		"-e FLOCI_VERSION=2.3.0",
		"--label com.docker.compose.project=infralab",
		"--label com.docker.compose.service=floci",
		"--mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
		"--mount type=volume,source=infralab-floci-data,target=/app/data",
		"-p 127.0.0.1:4566:4566/tcp",
		"--network infralab",
		"--network-alias floci",
		"--entrypoint /usr/local/bin/docker-entrypoint.sh",
	} {
		if !strings.Contains(cmd, want) {
			t.Errorf("run command lacks %q:\n%s", want, cmd)
		}
	}
	for _, unwanted := range []string{"0123456789abcdef0123456789abcdef", "--network-alias infralab-floci", "--network-alias 3f2a9c1d8e7b", "--privileged"} {
		if strings.Contains(cmd, unwanted) {
			t.Errorf("run command must not contain %q:\n%s", unwanted, cmd)
		}
	}
	if !strings.HasSuffix(cmd, " floci/floci:2.3.0 /app/application -Dquarkus.http.host=0.0.0.0") {
		t.Errorf("image then cmd must come last: %s", cmd)
	}
	names := []string{}
	for _, s := range got.Steps {
		names = append(names, s.Name)
	}
	if strings.Join(names, ",") != "inspect,remove-children,remove,create,wait-ready" {
		t.Errorf("steps = %v", names)
	}
}

func TestFlociReset_RemovesInstanceContainersAndVpcNetworksFlociLeftBehind(t *testing.T) {
	fake := flociFake()
	fake.respond("docker ps -a --filter name=floci-aws-", "floci-aws-ec2-i-1\nfloci-aws-ec2-fwd-i-1-80\n", 0)
	fake.respond("docker network ls --filter name=floci-aws-vpc-", "floci-aws-vpc-4566-ap-northeast-2-vpc-1\n", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/floci/reset", "", authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if !got.OK {
		t.Fatalf("ok=false, steps=%+v", got.Steps)
	}
	if n := len(fake.callsWithPrefix("docker rm -f -v floci-aws-ec2-i-1 floci-aws-ec2-fwd-i-1-80")); n != 1 {
		t.Errorf("children were not removed: %+v", fake.callsWithPrefix("docker rm"))
	}
	if n := len(fake.callsWithPrefix("docker network rm floci-aws-vpc-4566-ap-northeast-2-vpc-1")); n != 1 {
		t.Errorf("vpc network was not removed")
	}
	// 자식 정리가 Floci 제거보다 먼저다 — 순서가 바뀌면 Floci 가 사라진 뒤 자식 목록을 못 얻는 일은 없지만,
	// 새 Floci 가 뜬 뒤 옛 자식이 남아 있는 창이 생긴다.
	var order []string
	for _, c := range fake.calls {
		s := c.String()
		if strings.HasPrefix(s, "docker rm -f -v floci-aws-ec2") {
			order = append(order, "children")
		} else if strings.HasPrefix(s, "docker rm -f -v infralab-floci") {
			order = append(order, "floci")
		}
	}
	if strings.Join(order, ",") != "children,floci" {
		t.Errorf("order = %v", order)
	}
}

func TestFlociReset_MissingContainerFailsBeforeRemoving(t *testing.T) {
	fake := newFakeRunner()
	fake.respondFull("docker inspect --format {{json .}} infralab-floci", Result{Stderr: "Error: No such object: infralab-floci", ExitCode: 1})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/floci/reset", "", authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if got.OK || len(got.Steps) != 1 || !strings.Contains(got.Steps[0].Result, "ERROR") {
		t.Errorf("got %+v", got)
	}
	if n := len(fake.callsWithPrefix("docker rm")); n != 0 {
		t.Errorf("removed a container it could not inspect")
	}
}

func TestFlociReset_CreateFailureTellsHowToRecover(t *testing.T) {
	fake := flociFake()
	fake.respondFull("docker run -d --name infralab-floci", Result{Stderr: "docker: Error response from daemon: network infralab not found", ExitCode: 125})
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/floci/reset", "", authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if got.OK {
		t.Fatal("ok=true after a failed create")
	}
	last := got.Steps[len(got.Steps)-1]
	if last.Name != "create" || !strings.Contains(last.Result, "docker compose up -d floci") {
		t.Errorf("last step = %+v, want create with recovery hint", last)
	}
}

func TestFlociReset_ExitedContainerAfterCreateIsAFailure(t *testing.T) {
	fake := flociFake()
	fake.respond("docker inspect -f {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} infralab-floci", "exited", 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "POST", "/api/floci/reset", "", authed(nil))
	var got kindUpResponse
	decode(t, res, &got)
	if got.OK || !strings.Contains(got.Steps[len(got.Steps)-1].Result, "exited") {
		t.Errorf("got %+v", got)
	}
}

func TestFlociReset_IsPostOnlyAndExclusive(t *testing.T) {
	srv := newTestServer(t, newFakeRunner())
	if res := do(t, srv, "GET", "/api/floci/reset", "", authed(nil)); res.StatusCode != 405 {
		t.Errorf("GET → %d", res.StatusCode)
	}
	if res := do(t, srv, "POST", "/api/floci/reset", "", nil); res.StatusCode != 401 {
		t.Errorf("no token → %d", res.StatusCode)
	}
}
