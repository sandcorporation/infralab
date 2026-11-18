package main

import (
	"io"
	"log"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// 공개 주소로 열리므로 임시 토큰 하나가 몰아 부를 수 있는 수에 한도가 있다(토큰마다 따로).
func TestTokenLimiterBurstThenRefillPerToken(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := newTokenLimiter(60, 3, func() time.Time { return now }) // 초당 1개, 한 번에 3개

	for i := 0; i < 3; i++ {
		if !l.allow("a") {
			t.Fatalf("burst 안 %d번째가 막혔다", i+1)
		}
	}
	if l.allow("a") {
		t.Fatal("burst 를 넘었는데 받았다")
	}
	if !l.allow("b") {
		t.Fatal("다른 토큰까지 막혔다")
	}
	now = now.Add(time.Second)
	if !l.allow("a") || l.allow("a") {
		t.Fatal("1초 뒤에는 정확히 하나만 받아야 한다")
	}
	now = now.Add(time.Hour)
	for i := 0; i < 3; i++ {
		if !l.allow("a") {
			t.Fatal("오래 쉰 뒤에는 burst 만큼 다시 받아야 한다(넘치게 쌓이지는 않는다)")
		}
	}
	if l.allow("a") {
		t.Fatal("버킷이 burst 를 넘게 찼다")
	}
}

func TestTokenLimiterSweepsIdleBuckets(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := newTokenLimiter(60, 1, func() time.Time { return now })
	l.allow("old")
	now = now.Add(2 * idleAfter)
	l.allow("new")
	if _, ok := l.buckets["old"]; ok || len(l.buckets) != 1 {
		t.Fatalf("buckets = %v", l.buckets)
	}
}

func TestTokenLimiterZeroRateDisables(t *testing.T) {
	l := newTokenLimiter(0, 1, nil)
	for i := 0; i < 100; i++ {
		if !l.allow("a") {
			t.Fatal("0 이면 제한하지 않는다")
		}
	}
}

// 한도를 넘은 요청은 backend 에 묻지도·공급사를 부르지도 않고 429(공급사 꼴 rate_limit_error)로 막힌다.
func TestRateLimitedTokenIsRejectedBeforeBackendAndProvider(t *testing.T) {
	fb, bsrv := newFakeBackend(t)
	up, usrv := newUpstream(t, fixedReply(anthropicReply))
	cfg := config{
		BackendURL: bsrv.URL, ProxySecret: testSecret, AnthropicKey: testAnthropicKey, OpenAIKey: testOpenAIKey,
		AnthropicURL: usrv.URL, OpenAIURL: usrv.URL, TokenPerMinute: 1, TokenBurst: 2,
	}
	psrv := httptest.NewServer(newProxy(cfg, log.New(io.Discard, "", 0)))
	t.Cleanup(psrv.Close)
	h := &harness{backend: fb, upstream: up, proxy: psrv}

	for i := 0; i < 2; i++ {
		if resp, body := post(t, h.proxy.URL+"/anthropic/v1/messages", bearer("tok-ok"), `{"model":"m"}`); resp.StatusCode != 200 {
			t.Fatalf("%d번째 = %d %s", i+1, resp.StatusCode, body)
		}
	}
	authBefore, upBefore := len(h.backend.authCalls), h.upstream.calls()
	resp, body := post(t, psrv.URL+"/anthropic/v1/messages", bearer("tok-ok"), `{"model":"m"}`)
	if resp.StatusCode != 429 || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("한도 넘음 = %d %s", resp.StatusCode, body)
	}
	if !strings.Contains(body, `"rate_limit_error"`) || !strings.Contains(body, `"rate_limited"`) {
		t.Fatalf("본문 = %s", body)
	}
	if len(h.backend.authCalls) != authBefore || h.upstream.calls() != upBefore {
		t.Fatal("한도를 넘었는데 backend·공급사를 불렀다")
	}
	// 다른 토큰은 그대로 받는다.
	if resp, body := post(t, psrv.URL+"/openai/v1/chat/completions", bearer("tok-other"), `{"model":"m"}`); resp.StatusCode == 429 {
		t.Fatalf("다른 토큰이 막혔다: %s", body)
	}
}

func TestTokenRateComesFromEnvironment(t *testing.T) {
	t.Setenv("INFRALAB_PROXY_TOKEN_PER_MINUTE", "")
	t.Setenv("INFRALAB_PROXY_TOKEN_BURST", "")
	if cfg := configFromEnv(); cfg.TokenPerMinute != 120 || cfg.TokenBurst != 60 {
		t.Fatalf("기본값 = %d/%d", cfg.TokenPerMinute, cfg.TokenBurst)
	}
	t.Setenv("INFRALAB_PROXY_TOKEN_PER_MINUTE", "0")
	t.Setenv("INFRALAB_PROXY_TOKEN_BURST", "5")
	if cfg := configFromEnv(); cfg.TokenPerMinute != 0 || cfg.TokenBurst != 5 {
		t.Fatalf("환경변수 = %d/%d", cfg.TokenPerMinute, cfg.TokenBurst)
	}
}
