package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
)

// usageFrom 은 공급사 응답 본문(JSON 하나 또는 SSE)에서 입출력 토큰 수를 읽는다.
//
//   - Anthropic messages: `usage.input_tokens`(+ 캐시 입력)·`usage.output_tokens`. 스트리밍이면
//     `message_start` 의 `message.usage` 와 `message_delta` 의 `usage`(누적값).
//   - OpenAI chat completions: `usage.prompt_tokens`·`usage.completion_tokens`.
//   - OpenAI responses: `usage.input_tokens`·`usage.output_tokens`, 스트리밍이면 `response.completed` 의
//     `response.usage`.
//
// 스트리밍의 사용량은 누적값이라 사건마다 큰 쪽을 남긴다.
func usageFrom(body []byte) (in, out int) {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		return usageOfEvent(trimmed)
	}
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
		i, o := usageOfEvent([]byte(data))
		in, out = max(in, i), max(out, o)
	}
	return in, out
}

type usage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	PromptTokens             int `json:"prompt_tokens"`
	CompletionTokens         int `json:"completion_tokens"`
}

func (u *usage) counts() (int, int) {
	if u == nil {
		return 0, 0
	}
	in := u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens + u.PromptTokens
	out := u.OutputTokens + u.CompletionTokens
	return in, out
}

func usageOfEvent(data []byte) (int, int) {
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
		return 0, 0
	}
	in, out := ev.Usage.counts()
	if ev.Message != nil {
		i, o := ev.Message.Usage.counts()
		in, out = max(in, i), max(out, o)
	}
	if ev.Response != nil {
		i, o := ev.Response.Usage.counts()
		in, out = max(in, i), max(out, o)
	}
	return in, out
}
