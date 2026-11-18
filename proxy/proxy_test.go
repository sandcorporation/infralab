package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testSecret       = "proxy-shared-secret-0123456789"
	testAnthropicKey = "sk-ant-real-provider-key-abcdef"
	testOpenAIKey    = "sk-openai-real-provider-key-uvwxyz"
	testToken        = "exam-temp-token-1"
	fixedModel       = "claude-fixed-model"
	fixedCodexModel  = "gpt-fixed-model"
)

// fakeBackend 는 backend 의 프록시 전용 내부 API(#72 계약)를 흉내 낸다.
type fakeBackend struct {
	t         *testing.T
	mu        sync.Mutex
	reasons   map[string]string // 토큰 → 거절 사유(없으면 허용)
	models    map[string]string // 도구 → 고정 모델
	authCalls []map[string]string
	exchanges []exchange
	failAuth  bool
}

func newFakeBackend(t *testing.T) (*fakeBackend, *httptest.Server) {
	fb := &fakeBackend{
		t:       t,
		reasons: map[string]string{},
		models:  map[string]string{"claude_code": fixedModel, "codex": fixedCodexModel},
	}
	srv := httptest.NewServer(http.HandlerFunc(fb.serve))
	t.Cleanup(srv.Close)
	return fb, srv
}

func (fb *fakeBackend) serve(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer "+testSecret {
		http.Error(w, "bad secret", http.StatusUnauthorized)
		return
	}
	fb.mu.Lock()
	defer fb.mu.Unlock()
	switch r.URL.Path {
	case "/api/proxy/authorize":
		var in map[string]string
		_ = json.NewDecoder(r.Body).Decode(&in)
		fb.authCalls = append(fb.authCalls, in)
		if fb.failAuth {
			http.Error(w, "boom "+testSecret, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if reason, denied := fb.reasons[in["token"]]; denied {
			_ = json.NewEncoder(w).Encode(map[string]any{"allowed": false, "reason": reason, "model": nil, "remaining_tokens": nil})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"allowed": true, "reason": nil, "model": fb.models[in["tool"]], "remaining_tokens": 1000})
	case "/api/proxy/exchanges":
		var ex exchange
		_ = json.NewDecoder(r.Body).Decode(&ex)
		fb.exchanges = append(fb.exchanges, ex)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func (fb *fakeBackend) recorded() []exchange {
	fb.mu.Lock()
	defer fb.mu.Unlock()
	return append([]exchange(nil), fb.exchanges...)
}

// upstream 은 공급사 자리의 시험 서버. 받은 요청을 적고 handler 로 답한다.
type upstream struct {
	mu       sync.Mutex
	requests []*http.Request
	bodies   [][]byte
	handler  http.Handler
}

func newUpstream(t *testing.T, h http.Handler) (*upstream, *httptest.Server) {
	u := &upstream{handler: h}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		u.mu.Lock()
		u.requests = append(u.requests, r)
		u.bodies = append(u.bodies, body)
		u.mu.Unlock()
		r.Body = io.NopCloser(bytes.NewReader(body))
		u.handler.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return u, srv
}

func (u *upstream) calls() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return len(u.requests)
}

type harness struct {
	backend  *fakeBackend
	upstream *upstream
	proxy    *httptest.Server
	logs     *syncBuffer
}

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

func newHarness(t *testing.T, provider http.Handler) *harness {
	t.Helper()
	fb, bsrv := newFakeBackend(t)
	up, usrv := newUpstream(t, provider)
	logs := &syncBuffer{}
	cfg := config{
		BackendURL:   bsrv.URL,
		ProxySecret:  testSecret,
		AnthropicKey: testAnthropicKey,
		OpenAIKey:    testOpenAIKey,
		AnthropicURL: usrv.URL,
		OpenAIURL:    usrv.URL,
	}
	psrv := httptest.NewServer(newProxy(cfg, log.New(logs, "", 0)))
	t.Cleanup(psrv.Close)
	return &harness{backend: fb, upstream: up, proxy: psrv, logs: logs}
}

func post(t *testing.T, url string, headers map[string]string, body string) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, string(data)
}

func bearer(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

const anthropicReply = `{"id":"msg_up","type":"message","role":"assistant","model":"claude-fixed-model","content":[{"type":"text","text":"hello from upstream"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3}}`

func fixedReply(body string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Request-Id", "req_upstream")
		_, _ = io.WriteString(w, body)
	})
}

// AC: backend 가 허용한 Anthropic 요청은 고정 모델로 바뀌어 공급사로 가고, 응답이 그대로 돌아오며,
// 요청·응답·입출력 토큰 수가 exchanges 로 넘어간다.
func TestAnthropicAllowedRequestUsesFixedModelAndIsRecorded(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))
	reqBody := `{"model":"claude-opus-whatever","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}`

	resp, body := post(t, h.proxy.URL+"/anthropic/v1/messages", map[string]string{
		"Authorization": "Bearer " + testToken, "anthropic-version": "2023-06-01", "anthropic-beta": "some-beta",
	}, reqBody)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body %s", resp.StatusCode, body)
	}
	if body != anthropicReply {
		t.Fatalf("response not passed through as is:\n got %s\nwant %s", body, anthropicReply)
	}
	if resp.Header.Get("Request-Id") != "req_upstream" {
		t.Fatalf("upstream headers not passed through: %v", resp.Header)
	}
	if h.upstream.calls() != 1 {
		t.Fatalf("upstream calls = %d", h.upstream.calls())
	}
	up := h.upstream.requests[0]
	if up.URL.Path != "/v1/messages" {
		t.Fatalf("upstream path = %s", up.URL.Path)
	}
	if up.Header.Get("x-api-key") != testAnthropicKey {
		t.Fatalf("upstream must get the real provider key, got %q", up.Header.Get("x-api-key"))
	}
	if up.Header.Get("Authorization") != "" {
		t.Fatalf("temporary token leaked to provider: %q", up.Header.Get("Authorization"))
	}
	if up.Header.Get("anthropic-beta") != "some-beta" || up.Header.Get("anthropic-version") != "2023-06-01" {
		t.Fatalf("anthropic headers not forwarded: %v", up.Header)
	}
	var sent map[string]any
	if err := json.Unmarshal(h.upstream.bodies[0], &sent); err != nil {
		t.Fatal(err)
	}
	if sent["model"] != fixedModel {
		t.Fatalf("model sent upstream = %v, want %s", sent["model"], fixedModel)
	}
	if sent["max_tokens"].(float64) != 100 {
		t.Fatalf("other fields must be kept: %v", sent)
	}

	auth := h.backend.authCalls
	if len(auth) != 1 || auth[0]["token"] != testToken || auth[0]["tool"] != "claude_code" || auth[0]["client_id"] != "127.0.0.1" {
		t.Fatalf("authorize calls = %v", auth)
	}
	ex := h.backend.recorded()
	if len(ex) != 1 {
		t.Fatalf("exchanges = %d, want 1", len(ex))
	}
	got := ex[0]
	if got.Token != testToken || got.Tool != "claude_code" || got.Model != fixedModel || got.ClientID != "127.0.0.1" {
		t.Fatalf("exchange = %+v", got)
	}
	if got.InputTokens != 15 || got.OutputTokens != 5 {
		t.Fatalf("tokens = %d/%d, want 15/5", got.InputTokens, got.OutputTokens)
	}
	if got.Response != anthropicReply || !strings.Contains(got.Request, fixedModel) || !strings.Contains(got.Request, `"hi"`) {
		t.Fatalf("exchange request/response = %q / %q", got.Request, got.Response)
	}
}

func TestAnthropicAcceptsXAPIKey(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))

	resp, body := post(t, h.proxy.URL+"/anthropic/v1/messages", map[string]string{"x-api-key": testToken}, `{"model":"x","messages":[]}`)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body %s", resp.StatusCode, body)
	}
	if h.backend.authCalls[0]["token"] != testToken {
		t.Fatalf("authorize token = %q", h.backend.authCalls[0]["token"])
	}
	if h.upstream.requests[0].Header.Get("x-api-key") != testAnthropicKey {
		t.Fatal("x-api-key must be replaced by the real key")
	}
}

// AC: 거절 사유마다 정해진 상태 코드로 막히고 공급사는 불리지 않는다.
func TestDeniedReasonsAreBlockedWithoutCallingProvider(t *testing.T) {
	cases := map[string]int{
		"unknown":          401,
		"revoked":          401,
		"outside_window":   403,
		"tool_not_allowed": 403,
		"in_use_elsewhere": 403,
		"limit":            429,
	}
	paths := map[string]string{
		"/anthropic/v1/messages":      "anthropic",
		"/openai/v1/responses":        "openai",
		"/openai/v1/chat/completions": "openai",
	}
	for reason, status := range cases {
		for path, provider := range paths {
			t.Run(reason+path, func(t *testing.T) {
				h := newHarness(t, fixedReply(anthropicReply))
				h.backend.reasons["bad"] = reason

				resp, body := post(t, h.proxy.URL+path, bearer("bad"), `{"model":"m","messages":[]}`)

				if resp.StatusCode != status {
					t.Fatalf("status = %d, want %d (body %s)", resp.StatusCode, status, body)
				}
				var e struct {
					Type  string `json:"type"`
					Error struct {
						Type    string `json:"type"`
						Message string `json:"message"`
						Code    string `json:"code"`
					} `json:"error"`
				}
				if err := json.Unmarshal([]byte(body), &e); err != nil {
					t.Fatalf("error body not JSON: %s", body)
				}
				if e.Error.Code != reason || e.Error.Message == "" || e.Error.Type == "" {
					t.Fatalf("error body = %s", body)
				}
				if provider == "anthropic" && e.Type != "error" {
					t.Fatalf("anthropic error shape = %s", body)
				}
				if h.upstream.calls() != 0 {
					t.Fatal("provider must not be called on a denied request")
				}
				if n := len(h.backend.recorded()); n != 0 {
					t.Fatalf("denied request must not be recorded, got %d", n)
				}
			})
		}
	}
}

func TestMissingTokenIsUnknownWithoutCallingAnything(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))

	resp, _ := post(t, h.proxy.URL+"/anthropic/v1/messages", nil, `{"model":"m"}`)

	if resp.StatusCode != 401 || h.upstream.calls() != 0 || len(h.backend.authCalls) != 0 {
		t.Fatalf("status = %d, upstream = %d, authorize = %d", resp.StatusCode, h.upstream.calls(), len(h.backend.authCalls))
	}
}

func TestBackendFailureIsBadGatewayWithoutCallingProvider(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))
	h.backend.failAuth = true

	resp, _ := post(t, h.proxy.URL+"/anthropic/v1/messages", bearer(testToken), `{"model":"m"}`)

	if resp.StatusCode != http.StatusBadGateway || h.upstream.calls() != 0 {
		t.Fatalf("status = %d, upstream = %d", resp.StatusCode, h.upstream.calls())
	}
}

func TestUnknownPathAndNonJSONBody(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))

	resp, _ := post(t, h.proxy.URL+"/anthropic/v1/other", bearer(testToken), `{}`)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown path status = %d", resp.StatusCode)
	}
	resp, _ = post(t, h.proxy.URL+"/anthropic/v1/messages", bearer(testToken), `not json`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("non-JSON status = %d", resp.StatusCode)
	}
	if h.upstream.calls() != 0 {
		t.Fatal("provider must not be called")
	}
}

// AC: 스트리밍 응답이 조각 단위로 흘러가고 끝난 뒤 한 번 기록된다.
func TestStreamingFlowsChunkByChunkAndIsRecordedOnceAtTheEnd(t *testing.T) {
	release := make(chan struct{})
	first := "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":21,\"output_tokens\":1}}}\n\n"
	rest := "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" +
		"event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n" +
		"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
	h := newHarness(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, first)
		w.(http.Flusher).Flush()
		<-release
		_, _ = io.WriteString(w, rest)
	}))
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()

	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+"/anthropic/v1/messages", strings.NewReader(`{"model":"m","stream":true}`))
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content-type = %q", ct)
	}

	// 공급사가 아직 끝나지 않았는데 첫 조각이 클라이언트에 닿는다.
	got := make(chan string, 1)
	go func() {
		buf := make([]byte, len(first))
		_, err := io.ReadFull(resp.Body, buf)
		if err != nil {
			got <- "error: " + err.Error()
			return
		}
		got <- string(buf)
	}()
	select {
	case s := <-got:
		if s != first {
			t.Fatalf("first chunk = %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("first chunk did not arrive before the stream ended")
	}
	if n := len(h.backend.recorded()); n != 0 {
		t.Fatalf("recorded before the stream ended: %d", n)
	}

	close(release)
	tail, _ := io.ReadAll(resp.Body)
	if string(tail) != rest {
		t.Fatalf("rest of stream = %q", tail)
	}

	ex := waitExchanges(t, h.backend, 1)
	if len(ex) != 1 {
		t.Fatalf("exchanges = %d, want exactly 1", len(ex))
	}
	if ex[0].InputTokens != 21 || ex[0].OutputTokens != 9 {
		t.Fatalf("tokens = %d/%d, want 21/9", ex[0].InputTokens, ex[0].OutputTokens)
	}
	if ex[0].Response != first+rest {
		t.Fatalf("recorded response = %q", ex[0].Response)
	}
}

// waitExchanges 는 기록이 n 개가 될 때까지 잠깐 기다린다(핸들러가 응답을 다 흘린 뒤 기록한다).
func waitExchanges(t *testing.T, fb *fakeBackend, n int) []exchange {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ex := fb.recorded(); len(ex) >= n {
			time.Sleep(50 * time.Millisecond) // 더 오지 않는지 잠깐 본다
			return fb.recorded()
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fb.recorded()
}

// AC: Codex 의 OpenAI 꼴 경로도 같은 규칙으로 돈다.
func TestOpenAIPathsFollowTheSameRules(t *testing.T) {
	cases := []struct {
		path, reply   string
		upstreamPath  string
		wantIn, wantO int
	}{
		{"/openai/v1/responses", `{"id":"resp_1","object":"response","output":[],"usage":{"input_tokens":30,"output_tokens":4,"total_tokens":34}}`, "/v1/responses", 30, 4},
		{"/openai/v1/chat/completions", `{"id":"c1","object":"chat.completion","choices":[],"usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}`, "/v1/chat/completions", 8, 2},
	}
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			h := newHarness(t, fixedReply(c.reply))

			resp, body := post(t, h.proxy.URL+c.path, bearer(testToken), `{"model":"gpt-anything","input":"hello"}`)

			if resp.StatusCode != 200 || body != c.reply {
				t.Fatalf("status %d body %s", resp.StatusCode, body)
			}
			up := h.upstream.requests[0]
			if up.URL.Path != c.upstreamPath || up.Header.Get("Authorization") != "Bearer "+testOpenAIKey {
				t.Fatalf("upstream path %s auth %q", up.URL.Path, up.Header.Get("Authorization"))
			}
			var sent map[string]any
			_ = json.Unmarshal(h.upstream.bodies[0], &sent)
			if sent["model"] != fixedCodexModel {
				t.Fatalf("model = %v", sent["model"])
			}
			if h.backend.authCalls[0]["tool"] != "codex" {
				t.Fatalf("tool = %v", h.backend.authCalls[0])
			}
			ex := h.backend.recorded()
			if len(ex) != 1 || ex[0].Tool != "codex" || ex[0].Model != fixedCodexModel || ex[0].InputTokens != c.wantIn || ex[0].OutputTokens != c.wantO || ex[0].Response != c.reply {
				t.Fatalf("exchanges = %+v", ex)
			}
		})
	}
}

func TestOpenAIResponsesStreamingIsRecordedWithUsage(t *testing.T) {
	h := newHarness(t, fakeProvider())

	resp, body := post(t, h.proxy.URL+"/openai/v1/responses", bearer(testToken), `{"model":"x","input":"hi","stream":true}`)

	if resp.StatusCode != 200 || !strings.Contains(body, "response.completed") {
		t.Fatalf("status %d body %s", resp.StatusCode, body)
	}
	ex := waitExchanges(t, h.backend, 1)
	if len(ex) != 1 || ex[0].InputTokens == 0 || ex[0].OutputTokens != fakeOutputTokens {
		t.Fatalf("exchanges = %+v", ex)
	}
}

func TestOpenAIDoesNotAcceptXAPIKey(t *testing.T) {
	h := newHarness(t, fixedReply("{}"))

	resp, _ := post(t, h.proxy.URL+"/openai/v1/responses", map[string]string{"x-api-key": testToken}, `{"model":"m"}`)

	if resp.StatusCode != 401 || h.upstream.calls() != 0 {
		t.Fatalf("status %d upstream %d", resp.StatusCode, h.upstream.calls())
	}
}

// AC: 공유 비밀·공급사 키는 응답·로그에 찍히지 않는다.
func TestSecretsNeverAppearInResponsesOrLogs(t *testing.T) {
	h := newHarness(t, fixedReply(anthropicReply))
	h.backend.reasons["denied"] = "revoked"
	var outputs []string
	collect := func(resp *http.Response, body string) {
		var hdr bytes.Buffer
		_ = resp.Header.Write(&hdr)
		outputs = append(outputs, hdr.String(), body)
	}

	collect(post(t, h.proxy.URL+"/anthropic/v1/messages", bearer(testToken), `{"model":"m"}`))
	collect(post(t, h.proxy.URL+"/openai/v1/responses", bearer(testToken), `{"model":"m"}`))
	collect(post(t, h.proxy.URL+"/anthropic/v1/messages", bearer("denied"), `{"model":"m"}`))
	collect(post(t, h.proxy.URL+"/anthropic/v1/messages", nil, `{"model":"m"}`))
	collect(post(t, h.proxy.URL+"/nope", nil, `{}`))
	h.backend.failAuth = true
	collect(post(t, h.proxy.URL+"/anthropic/v1/messages", bearer(testToken), `{"model":"m"}`))
	h.backend.failAuth = false

	// 공급사에 닿지 못할 때 오류 글(주소 등)도 비밀 없이.
	broken := newProxyWithUpstream(t, h, "http://127.0.0.1:1")
	collect(post(t, broken+"/anthropic/v1/messages", bearer(testToken), `{"model":"m"}`))
	collect(post(t, broken+"/openai/v1/chat/completions", bearer(testToken), `{"model":"m"}`))

	logs := h.logs.String()
	if logs == "" {
		t.Fatal("expected some log lines")
	}
	for _, secret := range []string{testSecret, testAnthropicKey, testOpenAIKey} {
		for i, out := range outputs {
			if strings.Contains(out, secret) {
				t.Fatalf("output %d contains a secret: %s", i, out)
			}
		}
		if strings.Contains(logs, secret) {
			t.Fatalf("logs contain a secret:\n%s", logs)
		}
	}
	// 임시 토큰도 로그에 찍지 않는다.
	if strings.Contains(logs, testToken) {
		t.Fatalf("logs contain the temporary token:\n%s", logs)
	}
	// 기록(exchanges)으로 넘기는 요청 본문에도 키가 없다.
	for _, ex := range h.backend.recorded() {
		for _, secret := range []string{testSecret, testAnthropicKey, testOpenAIKey} {
			if strings.Contains(ex.Request, secret) || strings.Contains(ex.Response, secret) {
				t.Fatalf("exchange contains a secret: %+v", ex)
			}
		}
	}
}

// newProxyWithUpstream 은 같은 로그에 쓰고 공급사 주소만 다른 프록시를 띄운다.
func newProxyWithUpstream(t *testing.T, h *harness, upstreamURL string) string {
	t.Helper()
	_, bsrv := newFakeBackend(t)
	cfg := config{
		BackendURL: bsrv.URL, ProxySecret: testSecret,
		AnthropicKey: testAnthropicKey, OpenAIKey: testOpenAIKey,
		AnthropicURL: upstreamURL, OpenAIURL: upstreamURL,
	}
	srv := httptest.NewServer(newProxy(cfg, log.New(h.logs, "", 0)))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestSecretsComeFromEnvironment(t *testing.T) {
	t.Setenv("INFRALAB_EXAM_PROXY_SECRET", "s-env")
	t.Setenv("INFRALAB_ANTHROPIC_EXAM_KEY", "a-env")
	t.Setenv("INFRALAB_OPENAI_EXAM_KEY", "o-env")
	t.Setenv("INFRALAB_PROXY_BACKEND_URL", "http://backend:8000")
	t.Setenv("INFRALAB_PROXY_FAKE_PROVIDER", "")

	cfg := configFromEnv()

	if cfg.ProxySecret != "s-env" || cfg.AnthropicKey != "a-env" || cfg.OpenAIKey != "o-env" || cfg.BackendURL != "http://backend:8000" {
		t.Fatalf("cfg = %+v", cfg)
	}
	if cfg.FakeProviderMode || cfg.AnthropicURL != "https://api.anthropic.com" || cfg.OpenAIURL != "https://api.openai.com" {
		t.Fatalf("cfg = %+v", cfg)
	}
}

// AC: 가짜 공급사 모드(INFRALAB_PROXY_FAKE_PROVIDER=1)는 진짜 키 없이 결정적 응답을 준다.
func TestFakeProviderModeGivesDeterministicRepliesWithoutRealKeys(t *testing.T) {
	fb, bsrv := newFakeBackend(t)
	t.Setenv("INFRALAB_PROXY_FAKE_PROVIDER", "1")
	t.Setenv("INFRALAB_EXAM_PROXY_SECRET", testSecret)
	t.Setenv("INFRALAB_ANTHROPIC_EXAM_KEY", "")
	t.Setenv("INFRALAB_OPENAI_EXAM_KEY", "")
	t.Setenv("INFRALAB_PROXY_BACKEND_URL", bsrv.URL)

	cfg, stop, err := applyFakeProvider(configFromEnv())
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if !cfg.FakeProviderMode || !strings.HasPrefix(cfg.AnthropicURL, "http://127.0.0.1:") {
		t.Fatalf("cfg = %+v", cfg)
	}
	psrv := httptest.NewServer(newProxy(cfg, log.New(io.Discard, "", 0)))
	defer psrv.Close()

	for _, c := range []struct{ path, body string }{
		{"/anthropic/v1/messages", `{"model":"m","messages":[{"role":"user","content":"hi"}]}`},
		{"/anthropic/v1/messages", `{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`},
		{"/openai/v1/responses", `{"model":"m","input":"hi"}`},
		{"/openai/v1/responses", `{"model":"m","input":"hi","stream":true}`},
		{"/openai/v1/chat/completions", `{"model":"m","messages":[{"role":"user","content":"hi"}]}`},
		{"/openai/v1/chat/completions", `{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`},
	} {
		resp1, body1 := post(t, psrv.URL+c.path, bearer(testToken), c.body)
		resp2, body2 := post(t, psrv.URL+c.path, bearer(testToken), c.body)
		if resp1.StatusCode != 200 || resp2.StatusCode != 200 {
			t.Fatalf("%s: status %d/%d body %s", c.path, resp1.StatusCode, resp2.StatusCode, body1)
		}
		if body1 != body2 {
			t.Fatalf("%s: replies differ:\n%s\n%s", c.path, body1, body2)
		}
		if !strings.Contains(body1, "fake provider") && !strings.Contains(body1, "infralab fake") {
			t.Fatalf("%s: unexpected reply %s", c.path, body1)
		}
		if !strings.Contains(body1, fixedModel) && !strings.Contains(body1, fixedCodexModel) {
			t.Fatalf("%s: reply must name the fixed model: %s", c.path, body1)
		}
	}
	ex := waitExchanges(t, fb, 12)
	if len(ex) != 12 {
		t.Fatalf("exchanges = %d", len(ex))
	}
	for _, e := range ex {
		if e.InputTokens <= 0 || e.OutputTokens != fakeOutputTokens {
			t.Fatalf("fake usage = %+v", e)
		}
	}
}

func TestFakeAnthropicStreamReassemblesTheReply(t *testing.T) {
	srv := httptest.NewServer(fakeProvider())
	defer srv.Close()
	resp, body := post(t, srv.URL+"/v1/messages", nil, `{"model":"m","stream":true}`)
	if resp.StatusCode != 200 {
		t.Fatal(resp.StatusCode)
	}
	var text strings.Builder
	sc := bufio.NewScanner(strings.NewReader(body))
	for sc.Scan() {
		data, ok := strings.CutPrefix(sc.Text(), "data: ")
		if !ok {
			continue
		}
		var ev struct {
			Delta struct {
				Text string `json:"text"`
			} `json:"delta"`
		}
		_ = json.Unmarshal([]byte(data), &ev)
		text.WriteString(ev.Delta.Text)
	}
	if text.String() != FakeReply {
		t.Fatalf("reassembled = %q", text.String())
	}
}

func TestClientIDRule(t *testing.T) {
	p := &proxy{}
	r := httptest.NewRequest(http.MethodPost, "/anthropic/v1/messages", nil)
	r.RemoteAddr = "203.0.113.7:51234"
	r.Header.Set("X-Forwarded-For", "198.51.100.1, 10.0.0.1")
	if got := p.clientID(r); got != "203.0.113.7" {
		t.Fatalf("clientID = %q", got)
	}
	p.cfg.TrustForwarded = true
	if got := p.clientID(r); got != "198.51.100.1" {
		t.Fatalf("clientID with forwarded = %q", got)
	}
	r.Header.Del("X-Forwarded-For")
	if got := p.clientID(r); got != "203.0.113.7" {
		t.Fatalf("clientID without header = %q", got)
	}
}

func TestUsageFrom(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		in, out int
	}{
		{"anthropic", `{"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":1}}`, 4, 4},
		{"chat", `{"usage":{"prompt_tokens":5,"completion_tokens":6}}`, 5, 6},
		{"responses", `{"usage":{"input_tokens":7,"output_tokens":8}}`, 7, 8},
		{"anthropic sse", "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\nevent: message_delta\ndata: {\"usage\":{\"output_tokens\":12}}\n\n", 10, 12},
		{"chat sse", "data: {\"choices\":[]}\n\ndata: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n", 2, 3},
		{"responses sse", "event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":1}}}\n\n", 9, 1},
		{"error body", `{"error":{"message":"x"}}`, 0, 0},
		{"garbage", "nope", 0, 0},
	}
	for _, c := range cases {
		in, out := usageFrom([]byte(c.body))
		if in != c.in || out != c.out {
			t.Errorf("%s: got %d/%d want %d/%d", c.name, in, out, c.in, c.out)
		}
	}
}
