// infralab AI 프록시 — 시험 지원자의 Claude Code·Codex 와 공급사(Anthropic·OpenAI) 사이에 선다.
// 지원자는 응시 한 번짜리 임시 토큰을 들고 이 프록시를 공급사인 줄 알고 부른다. 프록시는 요청마다
// backend 의 프록시 전용 내부 API(`POST /api/proxy/authorize`)에 토큰을 물어 거절이면 막고, 허용이면
// 모델을 backend 가 준 고정 모델로 바꿔 공급사로 넘긴 뒤 요청·응답·사용량을 `POST /api/proxy/exchanges`
// 로 넘긴다. 진짜 공급사 키는 이 서비스만 환경변수로 갖는다.
package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

var version = "dev"

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// configFromEnv 는 환경변수에서 설정을 읽는다. 비밀(공유 비밀·공급사 키)은 환경변수에서만 온다.
// getenvInt 는 정수 환경변수. 비었거나 정수가 아니면 기본값.
func getenvInt(k string, d int) int {
	v, err := strconv.Atoi(os.Getenv(k))
	if err != nil {
		return d
	}
	return v
}

func configFromEnv() config {
	return config{
		BackendURL:       getenv("INFRALAB_PROXY_BACKEND_URL", "http://127.0.0.1:8000"),
		ProxySecret:      os.Getenv("INFRALAB_EXAM_PROXY_SECRET"),
		AnthropicKey:     os.Getenv("INFRALAB_ANTHROPIC_EXAM_KEY"),
		OpenAIKey:        os.Getenv("INFRALAB_OPENAI_EXAM_KEY"),
		AnthropicURL:     getenv("INFRALAB_PROXY_ANTHROPIC_URL", "https://api.anthropic.com"),
		OpenAIURL:        getenv("INFRALAB_PROXY_OPENAI_URL", "https://api.openai.com"),
		TrustForwarded:   os.Getenv("INFRALAB_PROXY_TRUST_FORWARDED") == "1",
		FakeProviderMode: os.Getenv("INFRALAB_PROXY_FAKE_PROVIDER") == "1",
		TokenPerMinute:   getenvInt("INFRALAB_PROXY_TOKEN_PER_MINUTE", 120),
		TokenBurst:       getenvInt("INFRALAB_PROXY_TOKEN_BURST", 60),
	}
}

func main() {
	cfg := configFromEnv()
	logger := log.New(os.Stderr, "", log.LstdFlags)
	if cfg.ProxySecret == "" {
		logger.Fatal("INFRALAB_EXAM_PROXY_SECRET is required")
	}
	cfg, stop, err := applyFakeProvider(cfg)
	if err != nil {
		logger.Fatalf("fake provider: %v", err)
	}
	defer stop()
	if cfg.FakeProviderMode {
		logger.Printf("fake provider mode: deterministic replies, no real provider keys used")
	} else if cfg.AnthropicKey == "" && cfg.OpenAIKey == "" {
		logger.Printf("warning: neither INFRALAB_ANTHROPIC_EXAM_KEY nor INFRALAB_OPENAI_EXAM_KEY is set")
	}
	addr := getenv("INFRALAB_PROXY_ADDR", ":58090")
	logger.Printf("infralab-proxy %s listening on %s (backend: %s)", version, addr, cfg.BackendURL)
	srv := &http.Server{
		Addr:              addr,
		Handler:           newProxy(cfg, logger),
		ReadHeaderTimeout: 30 * time.Second,
	}
	logger.Fatal(srv.ListenAndServe())
}

// applyFakeProvider 는 가짜 공급사 모드면 프로세스 안 가짜 공급사를 띄우고 공급사 주소·키를 그쪽으로 바꾼다.
// 진짜 공급사 키는 쓰지 않는다(가짜 공급사로 가지 않게 지운다).
func applyFakeProvider(cfg config) (config, func(), error) {
	if !cfg.FakeProviderMode {
		return cfg, func() {}, nil
	}
	url, stop, err := startFakeProvider()
	if err != nil {
		return cfg, nil, err
	}
	cfg.AnthropicURL, cfg.OpenAIURL = url, url
	cfg.AnthropicKey, cfg.OpenAIKey = fakeProviderKey, fakeProviderKey
	return cfg, stop, nil
}
