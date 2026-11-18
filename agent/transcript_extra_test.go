package main

import (
	"strings"
	"testing"
)

func TestAITranscript_PathsWithSpacesSurviveTheFileList(t *testing.T) {
	spaced := "/root/.claude/projects/-work-my app/with space.jsonl"
	fake := transcriptFake()
	fake.respond(claudeFind, spaced+"\x00"+claudeFile1+"\x00", 0)
	fake.respond("docker exec infralab-workstation cat "+spaced, jl(claudeUser("2026-10-23T07:01:00.000Z", "공백 경로의 질문")), 0)
	fake.respond("docker exec infralab-workstation cat "+claudeFile1, jl(claudeUser("2026-10-23T07:02:00.000Z", "다른 파일")), 0)
	srv := newTestServer(t, fake)
	var got transcriptResponse
	decode(t, do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)), &got)
	c := got.Transcripts[0]
	if c.Error != "" || len(c.Entries) != 2 || c.Entries[0].Text != "공백 경로의 질문" {
		t.Errorf("claude = %+v", c)
	}
	finds := fake.callsWithPrefix(claudeFind)
	if len(finds) == 0 || !strings.HasSuffix(finds[0].String(), "-print0") {
		t.Errorf("find must use -print0")
	}
}

func TestAITranscript_CompactSummariesAreNotStudentWords(t *testing.T) {
	fake := transcriptFake()
	fake.respond(claudeFind, claudeFile1+"\x00", 0)
	summary := claudeUser("2026-10-23T07:03:00.000Z", "This session is being continued from a previous conversation... (자동 요약)")
	summary["isCompactSummary"] = true
	fake.respond("docker exec infralab-workstation cat "+claudeFile1, jl(claudeUser("2026-10-23T07:01:00.000Z", "질문"), summary), 0)
	srv := newTestServer(t, fake)
	var got transcriptResponse
	decode(t, do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)), &got)
	if e := got.Transcripts[0].Entries; len(e) != 1 || e[0].Text != "질문" {
		t.Errorf("entries = %+v", e)
	}
}

func TestPrepared_IsAFileExistenceCheckOnly(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respond("docker exec infralab-workstation test -f /work/.infralab/web-down.prepared", "", 0)
	fake.respondFull("docker exec infralab-workstation test -f /work/.infralab/never.prepared", Result{ExitCode: 1})
	srv := newTestServer(t, fake)
	if res := do(t, srv, "GET", "/api/prepared?scenario_id=web-down", "", authed(nil)); res.StatusCode != 200 {
		t.Errorf("prepared → %d, want 200", res.StatusCode)
	}
	if res := do(t, srv, "GET", "/api/prepared?scenario_id=never", "", authed(nil)); res.StatusCode != 404 {
		t.Errorf("unprepared → %d, want 404", res.StatusCode)
	}
	if n := len(fake.callsWithPrefix("docker exec infralab-workstation find")) + len(fake.callsWithPrefix("docker exec infralab-workstation cat")); n != 0 {
		t.Errorf("session files were read (%d calls)", n)
	}
	for path, want := range map[string]int{"/api/prepared": 400, "/api/prepared?scenario_id=Bad_ID": 400} {
		if res := do(t, srv, "GET", path, "", authed(nil)); res.StatusCode != want {
			t.Errorf("%s → %d, want %d", path, res.StatusCode, want)
		}
	}
	if res := do(t, srv, "GET", "/api/prepared?scenario_id=web-down", "", nil); res.StatusCode != 401 {
		t.Errorf("no token → %d", res.StatusCode)
	}
	if res := do(t, srv, "POST", "/api/prepared?scenario_id=web-down", "", authed(nil)); res.StatusCode != 405 {
		t.Errorf("POST → %d", res.StatusCode)
	}
	down := newFakeRunner()
	down.respondFull("docker exec infralab-workstation test", Result{Stderr: "Error response from daemon: No such container", ExitCode: 1})
	if res := do(t, newTestServer(t, down), "GET", "/api/prepared?scenario_id=web-down", "", authed(nil)); res.StatusCode != 503 {
		t.Errorf("docker failure → %d, want 503", res.StatusCode)
	}
}
