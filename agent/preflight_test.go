package main

import "testing"

// 엔진에 닿지 못하면 뒤 항목은 통과로 보이지 않고, docker info 도 부르지 않는다.
func TestPreflight_EngineDownLeavesOthersUnchecked(t *testing.T) {
	fake := newFakeRunner()
	fake.respondFull("docker version", Result{Stderr: "Cannot connect to the Docker daemon", ExitCode: 1})

	body := preflight(t, fake)

	for _, c := range body.Checks {
		if c.OK || c.Message == "" || c.HelpURL == "" {
			t.Fatalf("check %s with the engine down = %+v, want a failure with message and help", c.ID, c)
		}
	}
	if calls := fake.callsWithPrefix("docker info"); len(calls) != 0 {
		t.Fatalf("docker info called with the engine down: %v", calls)
	}
}

// 권한이 없을 때 원인은 permission 항목이고, 다른 항목은 그것을 가리킨다.
func TestPreflight_PermissionDeniedPointsAtPermission(t *testing.T) {
	fake := newFakeRunner()
	fake.respondFull("docker version", Result{Stderr: "connect: Permission denied", ExitCode: 1})

	body := preflight(t, fake)

	for _, c := range body.Checks {
		if c.OK || c.HelpURL != helpPermission {
			t.Fatalf("check %s with permission denied = %+v, want a failure pointing at %s", c.ID, c, helpPermission)
		}
	}
}
