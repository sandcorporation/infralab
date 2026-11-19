package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// verdict 는 backend `POST /api/proxy/authorize` 의 응답(#72 계약).
type verdict struct {
	Allowed         bool    `json:"allowed"`
	Reason          *string `json:"reason"`
	Model           *string `json:"model"`
	RemainingTokens *int    `json:"remaining_tokens"`
}

// exchange 는 backend `POST /api/proxy/exchanges` 의 본문(#72 계약).
type exchange struct {
	Token        string `json:"token"`
	Tool         string `json:"tool"`
	Model        string `json:"model"`
	ClientID     string `json:"client_id"`
	InputTokens  int    `json:"input_tokens"`
	OutputTokens int    `json:"output_tokens"`
	// 캐시 읽기·쓰기 입력(InputTokens 에 이미 들어 있다). 응답에 필드가 없으면 보내지 않는다(#252).
	CacheReadInputTokens     *int   `json:"cache_read_input_tokens,omitempty"`
	CacheCreationInputTokens *int   `json:"cache_creation_input_tokens,omitempty"`
	Request                  string `json:"request"`
	Response                 string `json:"response"`
}

// backendClient 는 backend 의 프록시 전용 내부 API 를 공유 비밀로 부른다.
type backendClient struct {
	base   string
	secret string
	http   *http.Client
}

func newBackendClient(base, secret string) *backendClient {
	return &backendClient{base: strings.TrimRight(base, "/"), secret: secret, http: &http.Client{Timeout: 30 * time.Second}}
}

func (b *backendClient) post(ctx context.Context, path string, body any) (*http.Response, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.base+path, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+b.secret)
	return b.http.Do(req)
}

func (b *backendClient) authorize(ctx context.Context, token, tool, clientID string) (verdict, error) {
	var v verdict
	resp, err := b.post(ctx, "/api/proxy/authorize", map[string]string{"token": token, "tool": tool, "client_id": clientID})
	if err != nil {
		return v, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return v, fmt.Errorf("authorize: backend status %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		return v, fmt.Errorf("authorize: %w", err)
	}
	return v, nil
}

func (b *backendClient) recordExchange(ctx context.Context, ex exchange) error {
	resp, err := b.post(ctx, "/api/proxy/exchanges", ex)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("exchanges: backend status %d", resp.StatusCode)
	}
	return nil
}
