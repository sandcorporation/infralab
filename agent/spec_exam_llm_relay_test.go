package main

// target: agent/spec_exam_llm_relay_test.go
// AC: #79: agent POST /llm/v1/chat/completions(에이전트 토큰 필요)가 본문을 로컬 LLM 의 /v1/chat/completions 로 넘기고 응답을 그대로 돌려준다
// AC: #79: 중계한 대화가 /api/ai-transcript 의 local_llm 기록(model = 요청의 모델, 사용자 마지막 발화와 응답 발화)으로 나온다
// AC: #79: AGENT_LOCAL_LLM_URL 이 없으면 중계 502, /api/ai-transcript 는 claude·codex 둘만
//
// 로컬 LLM 은 httptest 서버(OpenAI 호환 흉내)로, workstation 의 docker 호출은 가짜 runner 로 바꾼다.
// 에이전트는 newHandler 에 config.LocalLLMURL 을 넣어 띄운다(main 은 AGENT_LOCAL_LLM_URL 에서 채운다).

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

const relayRequest = `{"model":"qwen2.5-coder:7b","stream":false,"messages":[` +
	`{"role":"system","content":"너는 인프라 조수다."},` +
	`{"role":"user","content":"예전 질문"},` +
	`{"role":"assistant","content":"예전 답"},` +
	`{"role":"user","content":"lab-site 버킷을 만들어 줘"}]}`

const relayResponse = `{"id":"chatcmpl-1","object":"chat.completion","model":"qwen2.5-coder:7b",` +
	`"choices":[{"index":0,"message":{"role":"assistant","content":"aws s3 mb s3://lab-site 를 실행하세요."},"finish_reason":"stop"}],` +
	`"usage":{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30}}`

type fakeLocalLLM struct {
	mu     sync.Mutex
	paths  []string
	bodies []string
}

func newFakeLocalLLM(t *testing.T) (*httptest.Server, *fakeLocalLLM) {
	t.Helper()
	rec := &fakeLocalLLM{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		rec.mu.Lock()
		rec.paths = append(rec.paths, r.URL.Path)
		rec.bodies = append(rec.bodies, string(raw))
		rec.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, relayResponse)
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

func newRelayServer(t *testing.T, fake *fakeRunner, localLLMURL string) *httptest.Server {
	t.Helper()
	cfg := config{
		Token:          testToken,
		AllowedOrigins: []string{"https://lab.example.com"},
		Workstation:    "infralab-workstation",
		Floci:          "infralab-floci",
		KindCluster:    "infralab",
		LocalLLMURL:    localLLMURL,
	}
	srv := httptest.NewServer(newHandler(cfg, fake))
	t.Cleanup(srv.Close)
	return srv
}

type relayTranscriptResponse struct {
	Transcripts []struct {
		Tool    string `json:"tool"`
		Model   string `json:"model"`
		Entries []struct {
			Role string `json:"role"`
			Text string `json:"text"`
		} `json:"entries"`
	} `json:"transcripts"`
}

func TestSpecExamLLMRelay_PassesTheBodyThroughAndReturnsTheAnswer(t *testing.T) {
	llm, rec := newFakeLocalLLM(t)
	srv := newRelayServer(t, transcriptFake(), llm.URL)

	res := do(t, srv, "POST", "/llm/v1/chat/completions", relayRequest, authed(map[string]string{"Content-Type": "application/json"}))

	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	raw, _ := io.ReadAll(res.Body)
	res.Body.Close()
	var got, want any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("relay answer is not JSON: %v (%q)", err, raw)
	}
	_ = json.Unmarshal([]byte(relayResponse), &want)
	gotJSON, _ := json.Marshal(got)
	wantJSON, _ := json.Marshal(want)
	if string(gotJSON) != string(wantJSON) {
		t.Fatalf("relay answer = %s, want the local LLM's answer %s", gotJSON, wantJSON)
	}
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.paths) != 1 || rec.paths[0] != "/v1/chat/completions" {
		t.Fatalf("local LLM paths = %v, want [/v1/chat/completions]", rec.paths)
	}
	var sent, original any
	_ = json.Unmarshal([]byte(rec.bodies[0]), &sent)
	_ = json.Unmarshal([]byte(relayRequest), &original)
	sentJSON, _ := json.Marshal(sent)
	originalJSON, _ := json.Marshal(original)
	if string(sentJSON) != string(originalJSON) {
		t.Fatalf("local LLM got %s, want the request body %s", sentJSON, originalJSON)
	}
}

func TestSpecExamLLMRelay_NeedsTheAgentToken(t *testing.T) {
	llm, rec := newFakeLocalLLM(t)
	srv := newRelayServer(t, transcriptFake(), llm.URL)

	res := do(t, srv, "POST", "/llm/v1/chat/completions", relayRequest, map[string]string{"Content-Type": "application/json"})
	res.Body.Close()

	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", res.StatusCode)
	}
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.paths) != 0 {
		t.Fatalf("local LLM was called without a token: %v", rec.paths)
	}
}

func TestSpecExamLLMRelay_RelayedTalkShowsUpAsLocalLLMTranscript(t *testing.T) {
	llm, _ := newFakeLocalLLM(t)
	srv := newRelayServer(t, transcriptFake(), llm.URL)
	relay := do(t, srv, "POST", "/llm/v1/chat/completions", relayRequest, authed(map[string]string{"Content-Type": "application/json"}))
	relay.Body.Close()
	if relay.StatusCode != http.StatusOK {
		t.Fatalf("relay status = %d, want 200", relay.StatusCode)
	}

	res := do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	if res.StatusCode != http.StatusOK {
		t.Fatalf("transcript status = %d, want 200", res.StatusCode)
	}
	var body relayTranscriptResponse
	decode(t, res, &body)

	tools := map[string]int{}
	for i, tr := range body.Transcripts {
		tools[tr.Tool] = i
	}
	for _, name := range []string{"claude", "codex", "local_llm"} {
		if _, ok := tools[name]; !ok {
			t.Fatalf("transcripts have no %s: %+v", name, body.Transcripts)
		}
	}
	local := body.Transcripts[tools["local_llm"]]
	if local.Model != "qwen2.5-coder:7b" {
		t.Fatalf("local_llm model = %q, want the requested model", local.Model)
	}
	if len(local.Entries) != 2 {
		t.Fatalf("local_llm entries = %+v, want the last user turn and the answer", local.Entries)
	}
	if local.Entries[0].Role != "user" || local.Entries[0].Text != "lab-site 버킷을 만들어 줘" {
		t.Fatalf("first entry = %+v, want the last user message", local.Entries[0])
	}
	if local.Entries[1].Role != "assistant" || local.Entries[1].Text != "aws s3 mb s3://lab-site 를 실행하세요." {
		t.Fatalf("second entry = %+v, want the local LLM's answer", local.Entries[1])
	}
}

func TestSpecExamLLMRelay_WithoutLocalLLMURLRelayIs502AndTranscriptKeepsItsShape(t *testing.T) {
	srv := newRelayServer(t, transcriptFake(), "")

	res := do(t, srv, "POST", "/llm/v1/chat/completions", relayRequest, authed(map[string]string{"Content-Type": "application/json"}))
	res.Body.Close()
	if res.StatusCode != http.StatusBadGateway {
		t.Fatalf("relay status = %d, want 502", res.StatusCode)
	}

	res = do(t, srv, "GET", "/api/ai-transcript?scenario_id=web-down", "", authed(nil))
	if res.StatusCode != http.StatusOK {
		t.Fatalf("transcript status = %d, want 200", res.StatusCode)
	}
	var body relayTranscriptResponse
	decode(t, res, &body)
	if len(body.Transcripts) != 2 || body.Transcripts[0].Tool != "claude" || body.Transcripts[1].Tool != "codex" {
		t.Fatalf("transcripts = %+v, want claude and codex only", body.Transcripts)
	}
}
