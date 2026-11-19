package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

type config struct {
	// BackendURL 은 backend 의 주소(프록시 전용 내부 API `/api/proxy/…` 가 붙는다).
	BackendURL string
	// ProxySecret 은 backend 와 나누는 공유 비밀(INFRALAB_EXAM_PROXY_SECRET).
	ProxySecret string
	// 진짜 공급사 키. 이 서비스만 갖는다.
	AnthropicKey string
	OpenAIKey    string
	// 공급사 주소(가짜 공급사 모드에서는 프로세스 안 가짜 공급사).
	AnthropicURL string
	OpenAIURL    string
	// TrustForwarded 면 client_id 를 X-Forwarded-For 의 첫 주소로 정한다(앞에 역프록시가 있을 때).
	TrustForwarded bool
	// FakeProviderMode 는 INFRALAB_PROXY_FAKE_PROVIDER=1.
	FakeProviderMode bool
	// 임시 토큰마다 분당 요청 수와 한 번에 몰아 쓸 수 있는 수(rate.go). TokenPerMinute 이 0 이면 제한 없음.
	TokenPerMinute int
	TokenBurst     int
}

const (
	maxRequestBody = 32 << 20
	// maxRecorded 는 기록으로 넘기는 응답 본문의 최대 크기. 클라이언트에는 전부 흘려 보낸다.
	maxRecorded = 8 << 20
)

// route 는 프록시가 받는 경로 하나.
type route struct {
	tool     string // backend 가 아는 도구 이름
	provider string // "anthropic" | "openai"
	upstream string // 공급사 쪽 경로
	// count 는 토큰 수만 세는 경로(Claude Code 의 /context 등). 같은 토큰 규칙으로 통과시키되 사용량 기록·요청 수 한도에는 세지 않는다.
	count bool
}

var routes = map[string]route{
	"/anthropic/v1/messages":              {tool: "claude_code", provider: "anthropic", upstream: "/v1/messages"},
	"/anthropic/v1/messages/count_tokens": {tool: "claude_code", provider: "anthropic", upstream: "/v1/messages/count_tokens", count: true},
	"/openai/v1/responses":                {tool: "codex", provider: "openai", upstream: "/v1/responses"},
	"/openai/v1/chat/completions":         {tool: "codex", provider: "openai", upstream: "/v1/chat/completions"},
}

// reasonStatus 는 backend 의 거절 사유 → 응답 상태 코드.
var reasonStatus = map[string]int{
	"unknown":          http.StatusUnauthorized,
	"revoked":          http.StatusUnauthorized,
	"outside_window":   http.StatusForbidden,
	"tool_not_allowed": http.StatusForbidden,
	"in_use_elsewhere": http.StatusForbidden,
	"limit":            http.StatusTooManyRequests,
}

var reasonMessage = map[string]string{
	"unknown":          "infralab: unknown exam token",
	"revoked":          "infralab: exam token has been revoked",
	"outside_window":   "infralab: exam time window is closed",
	"tool_not_allowed": "infralab: this AI tool is not allowed in this exam",
	"in_use_elsewhere": "infralab: exam token is in use from another client",
	"limit":            "infralab: exam token usage limit reached",
}

type proxy struct {
	cfg     config
	backend *backendClient
	client  *http.Client
	log     *log.Logger
	limiter *tokenLimiter
}

func newProxy(cfg config, logger *log.Logger) http.Handler {
	return &proxy{
		cfg:     cfg,
		backend: newBackendClient(cfg.BackendURL, cfg.ProxySecret),
		limiter: newTokenLimiter(cfg.TokenPerMinute, cfg.TokenBurst, nil),
		// 공급사 응답은 길게 흐를 수 있어 전체 시간 제한을 두지 않는다(요청 context 가 끊으면 끝난다).
		client: &http.Client{Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			ResponseHeaderTimeout: 10 * time.Minute,
			IdleConnTimeout:       90 * time.Second,
		}},
		log: logger,
	}
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"ok"}`)
		return
	}
	if r.URL.Path == "/providers" {
		p.serveProviders(w, r)
		return
	}
	rt, ok := routes[r.URL.Path]
	if !ok {
		provider := "openai"
		if strings.HasPrefix(r.URL.Path, "/anthropic/") {
			provider = "anthropic"
		}
		writeError(w, provider, http.StatusNotFound, "not_found", "infralab: unknown path")
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, rt.provider, http.StatusMethodNotAllowed, "method_not_allowed", "infralab: POST only")
		return
	}
	// 키가 빈 공급사로는 보내지 않는다 — 빈 키로 보내면 공급사 401 이 지원자에게 그대로 간다. backend 도 부르지 않는다(사용량에 세지 않음).
	if !p.cfg.configured(rt.provider) {
		p.log.Printf("%s %s tool=%s denied reason=provider_not_configured status=503", r.Method, r.URL.Path, rt.tool)
		writeError(w, rt.provider, http.StatusServiceUnavailable, "provider_not_configured", "infralab: this AI provider is not configured for exams")
		return
	}
	clientID := p.clientID(r)
	token := requestToken(r, rt.provider)
	if token == "" {
		p.deny(w, r, rt, clientID, "unknown")
		return
	}
	// backend 에 묻기 전에 막는다 — 틀린 토큰을 몰아 보내도 backend 를 그만큼 부르지 않는다.
	if !rt.count && !p.limiter.allow(token) {
		p.log.Printf("%s %s tool=%s client=%s denied reason=rate_limited status=429", r.Method, r.URL.Path, rt.tool, clientID)
		w.Header().Set("Retry-After", "1")
		writeError(w, rt.provider, http.StatusTooManyRequests, "rate_limited", "infralab: too many requests for this exam token")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBody))
	if err != nil {
		writeError(w, rt.provider, http.StatusRequestEntityTooLarge, "invalid_request", "infralab: request body too large or unreadable")
		return
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil || fields == nil {
		writeError(w, rt.provider, http.StatusBadRequest, "invalid_request", "infralab: request body must be a JSON object")
		return
	}

	v, err := p.backend.authorize(r.Context(), token, rt.tool, clientID)
	if err != nil {
		p.log.Printf("%s %s tool=%s client=%s backend authorize failed: %v", r.Method, r.URL.Path, rt.tool, clientID, err)
		writeError(w, rt.provider, http.StatusBadGateway, "backend_unavailable", "infralab: could not verify exam token")
		return
	}
	if !v.Allowed {
		reason := ""
		if v.Reason != nil {
			reason = *v.Reason
		}
		p.deny(w, r, rt, clientID, reason)
		return
	}

	model := ""
	if v.Model != nil {
		model = *v.Model
	}
	if model != "" {
		fields["model"], _ = json.Marshal(model)
	} else if raw, ok := fields["model"]; ok {
		_ = json.Unmarshal(raw, &model)
	}
	outBody, err := json.Marshal(fields)
	if err != nil {
		writeError(w, rt.provider, http.StatusBadRequest, "invalid_request", "infralab: request body must be a JSON object")
		return
	}

	resp, err := p.forward(r, rt, outBody)
	if err != nil {
		if r.Context().Err() == nil {
			p.log.Printf("%s %s tool=%s client=%s provider request failed: %v", r.Method, r.URL.Path, rt.tool, clientID, redact(err.Error(), p.secrets()))
			writeError(w, rt.provider, http.StatusBadGateway, "provider_unavailable", "infralab: provider request failed")
		}
		return
	}
	defer resp.Body.Close()

	recorded := streamResponse(w, resp)
	if rt.count {
		p.log.Printf("%s %s tool=%s model=%s client=%s status=%d count_tokens (not recorded)", r.Method, r.URL.Path, rt.tool, model, clientID, resp.StatusCode)
		return
	}
	u := usageFrom(recorded.Bytes())
	in, out := u.In, u.Out
	p.log.Printf("%s %s tool=%s model=%s client=%s status=%d input_tokens=%d output_tokens=%d",
		r.Method, r.URL.Path, rt.tool, model, clientID, resp.StatusCode, in, out)

	// 클라이언트가 끊어도 기록은 남긴다.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 30*time.Second)
	defer cancel()
	ex := exchange{
		Token:                    token,
		Tool:                     rt.tool,
		Model:                    model,
		ClientID:                 clientID,
		InputTokens:              in,
		OutputTokens:             out,
		CacheReadInputTokens:     u.CacheRead,
		CacheCreationInputTokens: u.CacheCreation,
		Request:                  string(outBody),
		Response:                 recorded.String(),
	}
	if err := p.backend.recordExchange(ctx, ex); err != nil {
		p.log.Printf("%s %s tool=%s client=%s record exchange failed: %v", r.Method, r.URL.Path, rt.tool, clientID, err)
	}
}

// configured 는 그 공급사의 키가 들어 있는지.
func (c config) configured(provider string) bool {
	if provider == "anthropic" {
		return c.AnthropicKey != ""
	}
	return c.OpenAIKey != ""
}

// serveProviders 는 backend 전용 — 공급사마다 키가 설정됐는지만 준다(키 값은 주지 않는다).
// backend 와 나누는 공유 비밀(Authorization: Bearer)이 맞아야 한다.
func (p *proxy) serveProviders(w http.ResponseWriter, r *http.Request) {
	got := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if p.cfg.ProxySecret == "" || subtle.ConstantTimeCompare([]byte(got), []byte(p.cfg.ProxySecret)) != 1 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"detail":"unauthorized"}`)
		return
	}
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]bool{
		"anthropic": p.cfg.configured("anthropic"),
		"openai":    p.cfg.configured("openai"),
	})
}

func (p *proxy) deny(w http.ResponseWriter, r *http.Request, rt route, clientID, reason string) {
	status, ok := reasonStatus[reason]
	if !ok {
		status, reason = http.StatusForbidden, "denied"
	}
	msg := reasonMessage[reason]
	if msg == "" {
		msg = "infralab: request denied"
	}
	p.log.Printf("%s %s tool=%s client=%s denied reason=%s status=%d", r.Method, r.URL.Path, rt.tool, clientID, reason, status)
	writeError(w, rt.provider, status, reason, msg)
}

func (p *proxy) secrets() []string {
	return []string{p.cfg.ProxySecret, p.cfg.AnthropicKey, p.cfg.OpenAIKey}
}

// clientID 는 요청을 보낸 곳. 원격 주소의 IP(포트 제외)이고, TrustForwarded 면 X-Forwarded-For 의 첫 주소.
func (p *proxy) clientID(r *http.Request) string {
	if p.cfg.TrustForwarded {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			first, _, _ := strings.Cut(xff, ",")
			if first = strings.TrimSpace(first); first != "" {
				return first
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// requestToken 은 클라이언트가 들고 온 임시 토큰. Anthropic 꼴은 x-api-key 도 받는다.
func requestToken(r *http.Request, provider string) string {
	if auth := r.Header.Get("Authorization"); auth != "" {
		if scheme, rest, ok := strings.Cut(auth, " "); ok && strings.EqualFold(scheme, "Bearer") {
			if t := strings.TrimSpace(rest); t != "" {
				return t
			}
		}
	}
	if provider == "anthropic" {
		return strings.TrimSpace(r.Header.Get("x-api-key"))
	}
	return ""
}

// 공급사로 넘기지 않는 요청 머리글(인증은 진짜 키로 바꾼다, 압축은 Go 가 풀게 둔다).
var dropRequestHeaders = map[string]bool{
	"Authorization": true, "X-Api-Key": true, "Host": true, "Content-Length": true,
	"Accept-Encoding": true, "Connection": true, "Keep-Alive": true, "Proxy-Authorization": true,
	"Proxy-Connection": true, "Te": true, "Trailer": true, "Transfer-Encoding": true, "Upgrade": true,
	"Cookie": true, "X-Forwarded-For": true, "X-Forwarded-Host": true, "X-Forwarded-Proto": true, "X-Real-Ip": true,
}

func (p *proxy) forward(r *http.Request, rt route, body []byte) (*http.Response, error) {
	base, key := p.cfg.OpenAIURL, p.cfg.OpenAIKey
	if rt.provider == "anthropic" {
		base, key = p.cfg.AnthropicURL, p.cfg.AnthropicKey
	}
	url := strings.TrimRight(base, "/") + rt.upstream
	if r.URL.RawQuery != "" {
		url += "?" + r.URL.RawQuery
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for k, vs := range r.Header {
		if dropRequestHeaders[http.CanonicalHeaderKey(k)] {
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Content-Type", "application/json")
	if rt.provider == "anthropic" {
		req.Header.Set("x-api-key", key)
		if req.Header.Get("anthropic-version") == "" {
			req.Header.Set("anthropic-version", "2023-06-01")
		}
	} else {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	return p.client.Do(req)
}

// 클라이언트로 넘기지 않는 응답 머리글.
var dropResponseHeaders = map[string]bool{
	"Content-Length": true, "Content-Encoding": true, "Connection": true, "Keep-Alive": true,
	"Transfer-Encoding": true, "Trailer": true, "Upgrade": true, "Set-Cookie": true,
}

// streamResponse 는 공급사 응답을 읽는 대로 클라이언트에 흘려 보내고(조각마다 flush), 기록할 본문을 돌려준다.
func streamResponse(w http.ResponseWriter, resp *http.Response) *bytes.Buffer {
	for k, vs := range resp.Header {
		if dropResponseHeaders[http.CanonicalHeaderKey(k)] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)
	if flusher != nil {
		flusher.Flush()
	}
	var recorded bytes.Buffer
	buf := make([]byte, 32<<10)
	clientGone := false
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if recorded.Len() < maxRecorded {
				recorded.Write(buf[:min(n, maxRecorded-recorded.Len())])
			}
			if !clientGone {
				if _, werr := w.Write(buf[:n]); werr != nil {
					clientGone = true
				} else if flusher != nil {
					flusher.Flush()
				}
			}
		}
		if err != nil {
			break
		}
	}
	return &recorded
}

// writeError 는 공급사 꼴의 오류 응답을 쓴다. Claude Code·Codex 가 그대로 읽고 사용자에게 보인다.
func writeError(w http.ResponseWriter, provider string, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	var body any
	if provider == "anthropic" {
		body = map[string]any{
			"type":  "error",
			"error": map[string]any{"type": anthropicErrorType(status), "message": message, "code": code},
		}
	} else {
		body = map[string]any{
			"error": map[string]any{"message": message, "type": openAIErrorType(status), "code": code, "param": nil},
		}
	}
	_ = json.NewEncoder(w).Encode(body)
}

func anthropicErrorType(status int) string {
	switch status {
	case http.StatusUnauthorized:
		return "authentication_error"
	case http.StatusForbidden:
		return "permission_error"
	case http.StatusTooManyRequests:
		return "rate_limit_error"
	case http.StatusNotFound:
		return "not_found_error"
	case http.StatusBadRequest, http.StatusRequestEntityTooLarge, http.StatusMethodNotAllowed:
		return "invalid_request_error"
	default:
		return "api_error"
	}
}

func openAIErrorType(status int) string {
	switch status {
	case http.StatusUnauthorized:
		return "invalid_request_error"
	case http.StatusForbidden:
		return "permission_error"
	case http.StatusTooManyRequests:
		return "insufficient_quota"
	case http.StatusBadRequest, http.StatusNotFound, http.StatusRequestEntityTooLarge, http.StatusMethodNotAllowed:
		return "invalid_request_error"
	default:
		return "server_error"
	}
}

// redact 는 글 안의 비밀을 가린다(로그에 공급사 키·공유 비밀이 찍히지 않게).
func redact(s string, secrets []string) string {
	for _, sec := range secrets {
		if len(sec) >= 4 {
			s = strings.ReplaceAll(s, sec, "[redacted]")
		}
	}
	return s
}
