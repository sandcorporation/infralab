package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

type transcriptResponse struct {
	ScenarioID  string `json:"scenario_id"`
	Since       string `json:"since"`
	Transcripts []struct {
		Tool      string `json:"tool"`
		Since     string `json:"since"`
		Truncated bool   `json:"truncated"`
		Error     string `json:"error"`
		Entries   []struct {
			Role string `json:"role"`
			At   string `json:"at"`
			Text string `json:"text"`
		} `json:"entries"`
	} `json:"transcripts"`
}

const (
	markCat     = "docker exec infralab-workstation cat /work/.infralab/web-down.prepared"
	claudeFind  = "docker exec infralab-workstation find /root/.claude/projects -name *.jsonl -type f -newer /work/.infralab/web-down.prepared"
	codexFind   = "docker exec infralab-workstation find /root/.codex/sessions -name rollout-*.jsonl -type f -newer /work/.infralab/web-down.prepared"
	claudeFile1 = "/root/.claude/projects/-work/aaa.jsonl"
	codexFile1  = "/root/.codex/sessions/2026/10/23/rollout-2026-10-23T07-10-00-xyz.jsonl"
)

func jl(objs ...map[string]any) string {
	var b strings.Builder
	for _, o := range objs {
		raw, _ := json.Marshal(o)
		b.Write(raw)
		b.WriteByte('\n')
	}
	return b.String()
}

func claudeUser(at, text string) map[string]any {
	return map[string]any{"type": "user", "isSidechain": false, "timestamp": at, "message": map[string]any{"role": "user", "content": text}}
}

func claudeAssistant(at string, blocks ...map[string]any) map[string]any {
	content := make([]any, len(blocks))
	for i, b := range blocks {
		content[i] = b
	}
	return map[string]any{"type": "assistant", "isSidechain": false, "timestamp": at, "message": map[string]any{"role": "assistant", "content": content}}
}

func textBlock(t string) map[string]any { return map[string]any{"type": "text", "text": t} }

func codexMsg(at, role, blockType, text string) map[string]any {
	return map[string]any{
		"type": "response_item", "timestamp": at,
		"payload": map[string]any{"type": "message", "role": role, "content": []any{map[string]any{"type": blockType, "text": text}}},
	}
}

func transcriptFake() *fakeRunner {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respond(markCat, "2026-10-23T07:00:00Z\n", 0)
	return fake
}

func TestAITranscript_MissingMarkIs404PrepareFirst(t *testing.T) {
	fake := withRunningWorkstation(newFakeRunner())
	fake.respondFull(markCat, Result{Stderr: "cat: can't open '/work/.infralab/web-down.prepared': No such file or directory", ExitCode: 1})
	srv := newTestServer(t, fake)
	res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", res.StatusCode)
	}
	if n := len(fake.callsWithPrefix("docker exec infralab-workstation find")); n != 0 {
		t.Errorf("sessions were read without a prepare mark")
	}
}

func TestAITranscript_ClaudeKeepsOnlyPromptsAndAssistantTextAfterTheMark(t *testing.T) {
	fake := transcriptFake()
	fake.respond(claudeFind, claudeFile1+"\n", 0)
	fake.respond("docker exec infralab-workstation cat "+claudeFile1, jl(
		claudeUser("2026-10-23T06:59:00.000Z", "준비 전 대화"), // 표시 이전
		claudeUser("2026-10-23T07:01:00.000Z", "web 이 왜 안 뜨지?"),
		map[string]any{"type": "attachment", "timestamp": "2026-10-23T07:01:00.100Z", "attachment": map[string]any{"type": "environment"}},
		claudeAssistant("2026-10-23T07:01:02.000Z", map[string]any{"type": "thinking", "thinking": "비공개 사고"}),
		claudeAssistant("2026-10-23T07:01:03.000Z", textBlock("Service 셀렉터를 확인해 볼게요.")),
		claudeAssistant("2026-10-23T07:01:04.000Z", map[string]any{"type": "tool_use", "id": "t1", "name": "Bash", "input": map[string]any{"command": "kubectl get svc"}}),
		map[string]any{"type": "user", "isSidechain": false, "timestamp": "2026-10-23T07:01:05.000Z", "message": map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": "NAME web"}}}},
		map[string]any{"type": "user", "isSidechain": false, "isMeta": true, "timestamp": "2026-10-23T07:01:06.000Z", "message": map[string]any{"role": "user", "content": "<local-command-caveat>x</local-command-caveat>"}},
		map[string]any{"type": "user", "isSidechain": false, "timestamp": "2026-10-23T07:01:07.000Z", "message": map[string]any{"role": "user", "content": "<system-reminder>숨김</system-reminder>"}},
		claudeUser("2026-10-23T07:01:08.000Z", "고쳐 줘"),
		map[string]any{"type": "assistant", "isSidechain": true, "timestamp": "2026-10-23T07:01:09.000Z", "message": map[string]any{"role": "assistant", "content": []any{textBlock("서브에이전트 발화")}}},
		map[string]any{"type": "assistant", "isSidechain": false, "isApiErrorMessage": true, "timestamp": "2026-10-23T07:01:10.000Z", "message": map[string]any{"role": "assistant", "content": []any{textBlock("Not logged in · Please run /login")}}},
		claudeAssistant("2026-10-23T07:01:11.000Z", textBlock("첫 줄"), textBlock("둘째 줄")),
	), 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var got transcriptResponse
	decode(t, res, &got)
	if got.ScenarioID != "web-down" || got.Since != "2026-10-23T07:00:00Z" {
		t.Errorf("header = %+v", got)
	}
	if len(got.Transcripts) != 2 || got.Transcripts[0].Tool != "claude" || got.Transcripts[1].Tool != "codex" {
		t.Fatalf("transcripts = %+v", got.Transcripts)
	}
	c := got.Transcripts[0]
	var lines []string
	for _, e := range c.Entries {
		lines = append(lines, e.Role+": "+e.Text)
	}
	want := []string{
		"user: web 이 왜 안 뜨지?",
		"assistant: Service 셀렉터를 확인해 볼게요.",
		"user: 고쳐 줘",
		"assistant: 첫 줄\n둘째 줄",
	}
	if strings.Join(lines, "|") != strings.Join(want, "|") {
		t.Errorf("entries =\n%q\nwant\n%q", lines, want)
	}
	if c.Since != "2026-10-23T07:00:00Z" || c.Truncated || c.Error != "" {
		t.Errorf("claude header = %+v", c)
	}
	if c.Entries[0].At != "2026-10-23T07:01:00.000Z" {
		t.Errorf("at = %q", c.Entries[0].At)
	}
	if n := len(got.Transcripts[1].Entries); n != 0 || got.Transcripts[1].Error != "" {
		t.Errorf("codex = %+v, want empty without error", got.Transcripts[1])
	}
}

func TestAITranscript_CodexKeepsMessageTextAndSkipsInjectedContext(t *testing.T) {
	fake := transcriptFake()
	fake.respond(codexFind, codexFile1+"\n", 0)
	fake.respond("docker exec infralab-workstation cat "+codexFile1, jl(
		map[string]any{"type": "session_meta", "timestamp": "2026-10-23T07:10:00.000Z", "payload": map[string]any{"cli_version": "0.164.0"}},
		codexMsg("2026-10-23T07:10:00.100Z", "developer", "input_text", "<permissions>..."),
		codexMsg("2026-10-23T07:10:00.200Z", "user", "input_text", "# AGENTS.md instructions for /work\n\n<INSTRUCTIONS>규칙</INSTRUCTIONS>"),
		codexMsg("2026-10-23T07:10:00.300Z", "user", "input_text", "<environment_context>\n<cwd>/work</cwd></environment_context>"),
		codexMsg("2026-10-23T06:00:00.000Z", "user", "input_text", "표시 이전 질문"),
		codexMsg("2026-10-23T07:10:01.000Z", "user", "input_text", "인스턴스에 왜 못 붙어?"),
		map[string]any{"type": "response_item", "timestamp": "2026-10-23T07:10:02.000Z", "payload": map[string]any{"type": "reasoning", "summary": []any{}}},
		map[string]any{"type": "response_item", "timestamp": "2026-10-23T07:10:03.000Z", "payload": map[string]any{"type": "function_call", "name": "shell", "arguments": "{}"}},
		map[string]any{"type": "event_msg", "timestamp": "2026-10-23T07:10:03.500Z", "payload": map[string]any{"type": "agent_message", "message": "중복 이벤트"}},
		codexMsg("2026-10-23T07:10:04.000Z", "assistant", "output_text", "보안 그룹을 확인해 보세요."),
	), 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	var got transcriptResponse
	decode(t, res, &got)
	cx := got.Transcripts[1]
	if cx.Tool != "codex" || cx.Error != "" || len(cx.Entries) != 2 {
		t.Fatalf("codex = %+v", cx)
	}
	if cx.Entries[0].Role != "user" || cx.Entries[0].Text != "인스턴스에 왜 못 붙어?" ||
		cx.Entries[1].Role != "assistant" || cx.Entries[1].Text != "보안 그룹을 확인해 보세요." {
		t.Errorf("entries = %+v", cx.Entries)
	}
}

func TestAITranscript_OverTheCapDropsTheOldestAndMarksTruncated(t *testing.T) {
	fake := transcriptFake()
	fake.respond(claudeFind, claudeFile1+"\n", 0)
	var objs []map[string]any
	big := strings.Repeat("가", 10_000) // 30KB
	for i := 0; i < 10; i++ {
		objs = append(objs, claudeUser(fmt.Sprintf("2026-10-23T07:%02d:00.000Z", i+1), fmt.Sprintf("%02d%s", i, big)))
	}
	fake.respond("docker exec infralab-workstation cat "+claudeFile1, jl(objs...), 0)
	srv := newTestServer(t, fake)

	var got transcriptResponse
	decode(t, do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)), &got)
	c := got.Transcripts[0]
	if !c.Truncated {
		t.Error("truncated=false, want true")
	}
	total := 0
	for _, e := range c.Entries {
		total += len(e.Text)
	}
	if total > maxTranscriptBytes {
		t.Errorf("total text = %d bytes, over the %d cap", total, maxTranscriptBytes)
	}
	last := c.Entries[len(c.Entries)-1]
	if !strings.HasPrefix(last.Text, "09") {
		t.Errorf("newest entry was dropped: %q", last.Text[:4])
	}
	if strings.HasPrefix(c.Entries[0].Text, "00") {
		t.Error("oldest entry survived the cap")
	}
}

func TestAITranscript_BrokenFileIsAnErrorForThatToolOnlyNot500(t *testing.T) {
	fake := transcriptFake()
	fake.respond(claudeFind, claudeFile1+"\n", 0)
	fake.respond("docker exec infralab-workstation cat "+claudeFile1, "{\"type\":\"user\"\nthis is not json at all\n{\"type\":\"user\"}\n", 0)
	fake.respond(codexFind, codexFile1+"\n", 0)
	fake.respond("docker exec infralab-workstation cat "+codexFile1, jl(codexMsg("2026-10-23T07:10:04.000Z", "assistant", "output_text", "정상")), 0)
	srv := newTestServer(t, fake)

	res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	if res.StatusCode != 200 {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var got transcriptResponse
	decode(t, res, &got)
	if got.Transcripts[0].Error == "" || len(got.Transcripts[0].Entries) != 0 {
		t.Errorf("claude = %+v, want empty entries with an error", got.Transcripts[0])
	}
	if got.Transcripts[1].Error != "" || len(got.Transcripts[1].Entries) != 1 {
		t.Errorf("codex = %+v, want its one entry", got.Transcripts[1])
	}
}

func TestAITranscript_AHalfWrittenLastLineIsIgnored(t *testing.T) {
	fake := transcriptFake()
	fake.respond(claudeFind, claudeFile1+"\n", 0)
	fake.respond("docker exec infralab-workstation cat "+claudeFile1,
		jl(claudeUser("2026-10-23T07:01:00.000Z", "질문"))+`{"type":"assistant","message":{"role":"assis`, 0)
	srv := newTestServer(t, fake)
	var got transcriptResponse
	decode(t, do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)), &got)
	if got.Transcripts[0].Error != "" || len(got.Transcripts[0].Entries) != 1 {
		t.Errorf("claude = %+v", got.Transcripts[0])
	}
}

func TestAITranscript_BadRequestsAuthAndMethod(t *testing.T) {
	srv := newTestServer(t, transcriptFake())
	for _, q := range []string{"", "?scenario_id=", "?scenario_id=Bad_ID", "?scenario_id=../x"} {
		if res := do(t, srv, "GET", "/api/ai-transcript"+q, "", authed(nil)); res.StatusCode != http.StatusBadRequest {
			t.Errorf("%q → %d, want 400", q, res.StatusCode)
		}
	}
	if res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", nil); res.StatusCode != 401 {
		t.Errorf("no token → %d", res.StatusCode)
	}
	if res := do(t, srv, "POST", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)); res.StatusCode != 405 {
		t.Errorf("POST → %d", res.StatusCode)
	}
	down := newFakeRunner()
	down.respond("docker inspect -f {{.State.Status}} infralab-workstation", "Error: No such object", 1)
	if res := do(t, newTestServer(t, down), "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)); res.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("workstation down → %d, want 503", res.StatusCode)
	}
}

func TestAITranscript_IsNotBlockedByAnEnvironmentOperation(t *testing.T) {
	// 읽기 전용이다 — 환경 작업이 도는 동안에도 준비 여부를 물을 수 있어야 화면이 멈추지 않는다.
	fake := transcriptFake()
	srv := newTestServer(t, fake)
	if res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil)); res.StatusCode != 200 {
		t.Errorf("status = %d", res.StatusCode)
	}
}
