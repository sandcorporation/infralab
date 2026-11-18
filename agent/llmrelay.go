package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// POST /llm/v1/chat/completions — 지원자 PC 의 로컬 LLM(OpenAI 호환, AGENT_LOCAL_LLM_URL)으로 AI 도구의 요청을
// 그대로 중계하고, 사용자 마지막 발화와 응답 발화를 기록한다. 기록은 /api/ai-transcript 에 도구 local_llm 으로 나온다.
// 에이전트 토큰이 필요하다(AI 도구는 브라우저가 아니라 Origin 이 없어도 토큰만 맞으면 된다). #79

const (
	maxRelayBody    = 8 << 20
	maxRelayRecords = 2000
)

type relayRecord struct {
	model string
	at    time.Time
	user  string
	reply string
}

type relayLog struct {
	mu   sync.Mutex
	recs []relayRecord
}

func (l *relayLog) add(r relayRecord) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.recs = append(l.recs, r)
	if len(l.recs) > maxRelayRecords {
		l.recs = l.recs[len(l.recs)-maxRelayRecords:]
	}
}

func (l *relayLog) snapshot() []relayRecord {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]relayRecord(nil), l.recs...)
}

type chatMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

// contentText 는 content 가 문자열이거나 {type:"text",text} 블록 목록일 때 글만 모은다.
func contentText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var parts []string
	for _, b := range blocks {
		if b.Type == "text" || b.Type == "" {
			parts = append(parts, b.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func (s *server) handleLLMRelay(w http.ResponseWriter, r *http.Request) {
	if s.cfg.LocalLLMURL == "" {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": "AGENT_LOCAL_LLM_URL is not set"})
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRelayBody))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "could not read the request body"})
		return
	}
	var req struct {
		Model    string        `json:"model"`
		Stream   bool          `json:"stream"`
		Messages []chatMessage `json:"messages"`
	}
	_ = json.Unmarshal(body, &req)
	user := ""
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role == "user" {
			user = strings.TrimSpace(contentText(req.Messages[i].Content))
			break
		}
	}

	target := strings.TrimRight(s.cfg.LocalLLMURL, "/") + "/v1/chat/completions"
	out, err := http.NewRequestWithContext(r.Context(), http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": "bad AGENT_LOCAL_LLM_URL"})
		return
	}
	out.Header.Set("Content-Type", "application/json")
	if a := r.Header.Get("Accept"); a != "" {
		out.Header.Set("Accept", a)
	}
	// 에이전트 토큰은 로컬 LLM 에 넘기지 않는다.
	res, err := http.DefaultClient.Do(out)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": "local LLM unreachable: " + err.Error()})
		return
	}
	defer res.Body.Close()
	if ct := res.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(res.StatusCode)

	var reply string
	if req.Stream {
		reply = relayStream(w, res.Body)
	} else {
		raw, _ := io.ReadAll(res.Body)
		_, _ = w.Write(raw)
		reply = replyFromCompletion(raw)
	}
	if res.StatusCode/100 == 2 && (user != "" || reply != "") {
		s.relay.add(relayRecord{model: req.Model, at: time.Now().UTC(), user: user, reply: reply})
	}
}

func replyFromCompletion(raw []byte) string {
	var c struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if json.Unmarshal(raw, &c) != nil || len(c.Choices) == 0 {
		return ""
	}
	return strings.TrimSpace(contentText(c.Choices[0].Message.Content))
}

// relayStream 은 SSE 를 줄 단위로 흘려 보내면서 delta.content 를 모은다.
func relayStream(w http.ResponseWriter, body io.Reader) string {
	flusher, _ := w.(http.Flusher)
	var sb strings.Builder
	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 0, 64*1024), 4<<20)
	for sc.Scan() {
		line := sc.Text()
		_, _ = io.WriteString(w, line+"\n")
		if flusher != nil {
			flusher.Flush()
		}
		data, ok := strings.CutPrefix(line, "data:")
		if !ok {
			continue
		}
		var ch struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(data)), &ch) == nil && len(ch.Choices) > 0 {
			sb.WriteString(ch.Choices[0].Delta.Content)
		}
	}
	return strings.TrimSpace(sb.String())
}

// localLLMTranscript 는 준비 표시 시각 이후의 중계 기록을 도구 local_llm 한 칸으로 만든다. 모델은 마지막 요청의 자기 신고.
func (s *server) localLLMTranscript(sinceText string, since time.Time) toolTranscript {
	out := toolTranscript{Tool: "local_llm", Since: sinceText, Entries: []transcriptEntry{}}
	for _, rec := range s.relay.snapshot() {
		if rec.at.Before(since) {
			continue
		}
		at := rec.at.Format(time.RFC3339Nano)
		if rec.model != "" {
			out.Model = rec.model
		}
		if rec.user != "" {
			out.Entries = append(out.Entries, transcriptEntry{Role: "user", At: at, Text: rec.user, when: rec.at})
		}
		if rec.reply != "" {
			out.Entries = append(out.Entries, transcriptEntry{Role: "assistant", At: at, Text: rec.reply, when: rec.at})
		}
	}
	for i := range out.Entries {
		if len(out.Entries[i].Text) > maxEntryBytes {
			out.Entries[i].Text, _ = clip(out.Entries[i].Text, maxEntryBytes)
			out.Truncated = true
		}
	}
	return out
}
