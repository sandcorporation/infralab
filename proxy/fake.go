package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

// 가짜 공급사 모드(INFRALAB_PROXY_FAKE_PROVIDER=1): 진짜 키·네트워크 없이 결정적 응답과 사용량을 준다.
// 프로세스 안 127.0.0.1 의 임시 포트에 가짜 공급사를 띄우고 공급사 주소를 그쪽으로 돌린다. 그래서 프록시의
// 나머지 길(머리글·스트리밍·기록)은 진짜 공급사와 똑같이 돈다.

// fakeProviderKey 는 가짜 공급사 모드에서 공급사 키 자리에 넣는 값(진짜 키가 아니다).
const fakeProviderKey = "fake-provider-key"

// FakeReply 는 가짜 공급사가 늘 돌려주는 대답.
const FakeReply = "infralab fake provider reply."

// fakeOutputTokens 는 가짜 대답의 출력 토큰 수.
const fakeOutputTokens = 7

// fakeInputTokens 는 요청 본문 크기로 정하는 결정적 입력 토큰 수(대략 4바이트에 1토큰).
func fakeInputTokens(body []byte) int { return len(body)/4 + 1 }

func startFakeProvider() (url string, stop func(), err error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: fakeProvider()}
	go func() { _ = srv.Serve(ln) }()
	return "http://" + ln.Addr().String(), func() { _ = srv.Close() }, nil
}

// fakeProvider 는 Anthropic messages·OpenAI chat completions·responses 꼴로 결정적 응답을 준다.
func fakeProvider() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		body, model, stream, ok := readFakeRequest(w, r)
		if !ok {
			return
		}
		in := fakeInputTokens(body)
		if !stream {
			writeJSON(w, map[string]any{
				"id": "msg_fake", "type": "message", "role": "assistant", "model": model,
				"content":     []any{map[string]any{"type": "text", "text": FakeReply}},
				"stop_reason": "end_turn", "stop_sequence": nil,
				"usage": map[string]any{"input_tokens": in, "output_tokens": fakeOutputTokens},
			})
			return
		}
		sse := newSSE(w)
		sse.event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
			"id": "msg_fake", "type": "message", "role": "assistant", "model": model, "content": []any{},
			"stop_reason": nil, "stop_sequence": nil, "usage": map[string]any{"input_tokens": in, "output_tokens": 1},
		}})
		sse.event("content_block_start", map[string]any{"type": "content_block_start", "index": 0,
			"content_block": map[string]any{"type": "text", "text": ""}})
		for _, piece := range fakePieces() {
			sse.event("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0,
				"delta": map[string]any{"type": "text_delta", "text": piece}})
		}
		sse.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
		sse.event("message_delta", map[string]any{"type": "message_delta",
			"delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil},
			"usage": map[string]any{"output_tokens": fakeOutputTokens}})
		sse.event("message_stop", map[string]any{"type": "message_stop"})
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		body, model, stream, ok := readFakeRequest(w, r)
		if !ok {
			return
		}
		in := fakeInputTokens(body)
		usage := map[string]any{"prompt_tokens": in, "completion_tokens": fakeOutputTokens, "total_tokens": in + fakeOutputTokens}
		if !stream {
			writeJSON(w, map[string]any{
				"id": "chatcmpl-fake", "object": "chat.completion", "created": 0, "model": model,
				"choices": []any{map[string]any{"index": 0, "finish_reason": "stop",
					"message": map[string]any{"role": "assistant", "content": FakeReply}}},
				"usage": usage,
			})
			return
		}
		sse := newSSE(w)
		chunk := func(delta map[string]any, finish any, u any) map[string]any {
			return map[string]any{"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": model,
				"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}, "usage": u}
		}
		sse.data(chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil))
		for _, piece := range fakePieces() {
			sse.data(chunk(map[string]any{"content": piece}, nil, nil))
		}
		sse.data(chunk(map[string]any{}, "stop", usage))
		sse.raw("[DONE]")
	})
	mux.HandleFunc("POST /v1/responses", func(w http.ResponseWriter, r *http.Request) {
		body, model, stream, ok := readFakeRequest(w, r)
		if !ok {
			return
		}
		in := fakeInputTokens(body)
		item := map[string]any{"type": "message", "id": "msg_fake", "status": "completed", "role": "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": FakeReply, "annotations": []any{}}}}
		done := map[string]any{"id": "resp_fake", "object": "response", "created_at": 0, "status": "completed",
			"model": model, "output": []any{item},
			"usage": map[string]any{"input_tokens": in, "output_tokens": fakeOutputTokens, "total_tokens": in + fakeOutputTokens}}
		if !stream {
			writeJSON(w, done)
			return
		}
		sse := newSSE(w)
		sse.event("response.created", map[string]any{"type": "response.created", "response": map[string]any{
			"id": "resp_fake", "object": "response", "created_at": 0, "status": "in_progress", "model": model, "output": []any{}}})
		sse.event("response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": 0,
			"item": map[string]any{"type": "message", "id": "msg_fake", "status": "in_progress", "role": "assistant", "content": []any{}}})
		for _, piece := range fakePieces() {
			sse.event("response.output_text.delta", map[string]any{"type": "response.output_text.delta",
				"item_id": "msg_fake", "output_index": 0, "content_index": 0, "delta": piece})
		}
		sse.event("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item})
		sse.event("response.completed", map[string]any{"type": "response.completed", "response": done})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":{"message":"fake provider: unknown path"}}`, http.StatusNotFound)
	})
	return mux
}

// fakePieces 는 스트리밍에서 대답을 나눠 보내는 조각들(이어 붙이면 FakeReply).
func fakePieces() []string {
	i := strings.Index(FakeReply, " provider")
	return []string{FakeReply[:i], FakeReply[i:]}
}

func readFakeRequest(w http.ResponseWriter, r *http.Request) (body []byte, model string, stream bool, ok bool) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return nil, "", false, false
	}
	var req struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, `{"error":{"message":"fake provider: invalid JSON"}}`, http.StatusBadRequest)
		return nil, "", false, false
	}
	return body, req.Model, req.Stream, true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

type sseWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func newSSE(w http.ResponseWriter) *sseWriter {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	f, _ := w.(http.Flusher)
	return &sseWriter{w: w, f: f}
}

func (s *sseWriter) flush() {
	if s.f != nil {
		s.f.Flush()
	}
}

func (s *sseWriter) event(name string, v any) {
	data, _ := json.Marshal(v)
	fmt.Fprintf(s.w, "event: %s\ndata: %s\n\n", name, data)
	s.flush()
}

func (s *sseWriter) data(v any) {
	data, _ := json.Marshal(v)
	s.raw(string(data))
}

func (s *sseWriter) raw(data string) {
	fmt.Fprintf(s.w, "data: %s\n\n", data)
	s.flush()
}
