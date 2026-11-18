package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

// 공급사 키는 하나만 있어도, 둘 다 없어도 기동한다. 공유 비밀만 필수다.
func TestStartupNeedsOnlyTheSharedSecret(t *testing.T) {
	cases := []struct {
		name              string
		anthropic, openai string
		wantNotes         int
	}{
		{"both", testAnthropicKey, testOpenAIKey, 0},
		{"anthropic only", testAnthropicKey, "", 1},
		{"openai only", "", testOpenAIKey, 1},
		{"none", "", "", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			notes, err := startupCheck(config{ProxySecret: testSecret, AnthropicKey: c.anthropic, OpenAIKey: c.openai})
			if err != nil || len(notes) != c.wantNotes {
				t.Fatalf("err = %v, notes = %q", err, notes)
			}
			for _, n := range notes {
				if strings.Contains(n, testAnthropicKey) || strings.Contains(n, testOpenAIKey) {
					t.Fatalf("note leaks a key: %q", n)
				}
			}
		})
	}
	if _, err := startupCheck(config{AnthropicKey: testAnthropicKey}); err == nil {
		t.Fatal("missing shared secret must stop startup")
	}
}

// 키가 빈 공급사 경로는 공급사·backend 를 부르지 않고 503 provider_not_configured(공급사 꼴 오류)를 낸다.
func TestUnconfiguredProviderIs503WithoutCallingProviderOrBackend(t *testing.T) {
	cases := []struct {
		path   string
		edit   func(*config)
		header map[string]string
	}{
		{"/anthropic/v1/messages", func(c *config) { c.AnthropicKey = "" }, bearer(testToken)},
		{"/anthropic/v1/messages/count_tokens", func(c *config) { c.AnthropicKey = "" }, map[string]string{"x-api-key": testToken}},
		{"/openai/v1/responses", func(c *config) { c.OpenAIKey = "" }, bearer(testToken)},
		{"/openai/v1/chat/completions", func(c *config) { c.OpenAIKey = "" }, bearer(testToken)},
	}
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			h := newHarnessWith(t, fixedReply(anthropicReply), c.edit)

			resp, body := post(t, h.proxy.URL+c.path, c.header, `{"model":"m"}`)

			if resp.StatusCode != http.StatusServiceUnavailable || resp.Header.Get("Content-Type") != "application/json" {
				t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
			}
			if h.upstream.calls() != 0 || len(h.backend.authCalls) != 0 || len(h.backend.recorded()) != 0 {
				t.Fatalf("upstream = %d, authorize = %d, recorded = %d", h.upstream.calls(), len(h.backend.authCalls), len(h.backend.recorded()))
			}
			var got struct {
				Type  string `json:"type"`
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.Unmarshal([]byte(body), &got); err != nil || got.Error.Code != "provider_not_configured" || got.Error.Message == "" {
				t.Fatalf("body = %s", body)
			}
			if strings.HasPrefix(c.path, "/anthropic/") != (got.Type == "error") {
				t.Fatalf("provider error shape: %s", body)
			}
		})
	}
}

// 다른 공급사는 그대로 돈다.
func TestConfiguredProviderStillWorksWhenTheOtherIsEmpty(t *testing.T) {
	h := newHarnessWith(t, fixedReply(anthropicReply), func(c *config) { c.OpenAIKey = "" })

	resp, body := post(t, h.proxy.URL+"/anthropic/v1/messages", bearer(testToken), `{"model":"m"}`)

	if resp.StatusCode != 200 || body != anthropicReply || h.upstream.calls() != 1 {
		t.Fatalf("status = %d, upstream = %d", resp.StatusCode, h.upstream.calls())
	}
}

func getProviders(t *testing.T, url, auth string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url+"/providers", nil)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /providers: %v", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data)
}

// backend 는 /providers 로 설정 여부만 받는다(공유 비밀 필수, 키 값은 없다).
func TestProvidersTellsOnlyWhetherEachKeyIsSet(t *testing.T) {
	h := newHarnessWith(t, fixedReply(anthropicReply), func(c *config) { c.OpenAIKey = "" })

	status, body := getProviders(t, h.proxy.URL, "Bearer "+testSecret)
	if status != 200 || strings.TrimSpace(body) != `{"anthropic":true,"openai":false}` {
		t.Fatalf("status = %d, body = %s", status, body)
	}
	for _, auth := range []string{"", "Bearer wrong", "Bearer " + testToken} {
		if status, body := getProviders(t, h.proxy.URL, auth); status != http.StatusUnauthorized || strings.Contains(body, "anthropic") {
			t.Fatalf("auth %q: status = %d, body = %s", auth, status, body)
		}
	}
}
