package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
)

// tokenUsage 는 응답 하나의 사용량이다. In 은 캐시 입력을 포함한 입력 합계이고, CacheRead·CacheCreation 은
// 응답에 그 필드가 있을 때만 값이 있다(없으면 nil — Anthropic 이 아닌 응답 등).
type tokenUsage struct {
	In, Out       int
	CacheRead     *int
	CacheCreation *int
}

// merge 는 스트리밍 사건 하나의 사용량(누적값)을 합친다. 필드마다 큰 쪽을 남긴다.
func (t *tokenUsage) merge(o tokenUsage) {
	t.In, t.Out = max(t.In, o.In), max(t.Out, o.Out)
	t.CacheRead = maxPtr(t.CacheRead, o.CacheRead)
	t.CacheCreation = maxPtr(t.CacheCreation, o.CacheCreation)
}

func maxPtr(a, b *int) *int {
	if a == nil {
		return b
	}
	if b == nil || *a >= *b {
		return a
	}
	return b
}

// usageFrom 은 공급사 응답 본문(JSON 하나 또는 SSE)에서 입출력 토큰 수를 읽는다.
//
//   - Anthropic messages: `usage.input_tokens`(+ 캐시 입력)·`usage.output_tokens`. 스트리밍이면
//     `message_start` 의 `message.usage` 와 `message_delta` 의 `usage`(누적값). 캐시 읽기·쓰기
//     (`cache_read_input_tokens`·`cache_creation_input_tokens`)는 입력 합계에 더하고 따로도 남긴다.
//   - OpenAI chat completions: `usage.prompt_tokens`·`usage.completion_tokens`.
//   - OpenAI responses: `usage.input_tokens`·`usage.output_tokens`, 스트리밍이면 `response.completed` 의
//     `response.usage`.
//
// 스트리밍의 사용량은 누적값이라 사건마다 큰 쪽을 남긴다.
func usageFrom(body []byte) tokenUsage {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		return usageOfEvent(trimmed)
	}
	var total tokenUsage
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 64<<10), maxRecorded)
	for sc.Scan() {
		line := sc.Text()
		data, ok := strings.CutPrefix(line, "data:")
		if !ok {
			continue
		}
		data = strings.TrimSpace(data)
		if data == "" || data == "[DONE]" {
			continue
		}
		total.merge(usageOfEvent([]byte(data)))
	}
	return total
}

type usage struct {
	InputTokens              int  `json:"input_tokens"`
	OutputTokens             int  `json:"output_tokens"`
	CacheCreationInputTokens *int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     *int `json:"cache_read_input_tokens"`
	PromptTokens             int  `json:"prompt_tokens"`
	CompletionTokens         int  `json:"completion_tokens"`
}

func (u *usage) counts() tokenUsage {
	if u == nil {
		return tokenUsage{}
	}
	in := u.InputTokens + deref(u.CacheCreationInputTokens) + deref(u.CacheReadInputTokens) + u.PromptTokens
	out := u.OutputTokens + u.CompletionTokens
	return tokenUsage{In: in, Out: out, CacheRead: u.CacheReadInputTokens, CacheCreation: u.CacheCreationInputTokens}
}

func deref(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func usageOfEvent(data []byte) tokenUsage {
	var ev struct {
		Usage   *usage `json:"usage"`
		Message *struct {
			Usage *usage `json:"usage"`
		} `json:"message"`
		Response *struct {
			Usage *usage `json:"usage"`
		} `json:"response"`
	}
	if json.Unmarshal(data, &ev) != nil {
		return tokenUsage{}
	}
	total := ev.Usage.counts()
	if ev.Message != nil {
		total.merge(ev.Message.Usage.counts())
	}
	if ev.Response != nil {
		total.merge(ev.Response.Usage.counts())
	}
	return total
}
