package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

// GET /api/ai-transcript?scenario_id= — 마지막 「환경 준비」 이후 workstation 안의 Claude Code·Codex 대화.
//
// 홈 볼륨의 준비 표시(~/.infralab/<id>.prepared)가 없으면 404 — 화면은 이것을 「환경 준비 먼저」로 읽는다.
// 있으면 표시 시각 이후에 바뀐 세션 파일을 runner(docker exec find/cat)로 읽어, 그 시각 이후의 사용자·어시스턴트
// 텍스트 발화만 추린다. 도구 호출·도구 결과·사고·시스템 메시지는 뺀다. 형식은 docs/ai-session-formats-2026-10-23.md.
//
// 응답: {"scenario_id","since","transcripts":[{"tool":"claude"|"codex","since","truncated","error"?,"entries":[{role,at,text}]}]}
// 도구마다 항목이 하나씩 온다(발화가 없으면 entries 가 빈 목록). 한 도구의 파일이 읽히지 않으면 그 도구만
// 빈 entries + error 이고 응답은 200 이다.

const (
	maxTranscriptBytes = 200 * 1024 // 두 도구 합계 텍스트 상한 — 넘으면 오래된 것부터 버린다
	maxEntryBytes      = 32 * 1024  // 발화 하나의 상한
	claudeRoot         = "/root/.claude/projects"
	codexRoot          = "/root/.codex/sessions"
)

type transcriptEntry struct {
	Role string `json:"role"`
	At   string `json:"at"`
	Text string `json:"text"`

	when time.Time
}

type toolTranscript struct {
	Tool      string            `json:"tool"`
	Since     string            `json:"since"`
	Truncated bool              `json:"truncated"`
	Error     string            `json:"error,omitempty"`
	Entries   []transcriptEntry `json:"entries"`
}

func (s *server) handleAITranscript(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("scenario_id")
	if !scenarioIDPattern.MatchString(id) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "scenario_id must be lowercase letters, digits and hyphens"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	if state := s.containerState(ctx, s.cfg.Workstation); state != "running" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "workstation is not running", "workstation": state})
		return
	}

	markPath := prepareMarkDir + "/" + id + ".prepared"
	res, err := s.runner.Run(ctx, "", "docker", "exec", s.cfg.Workstation, "cat", markPath)
	switch {
	case err != nil:
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "could not read the prepare mark: " + err.Error()})
		return
	case dockerLevelFailure(res):
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "workstation unavailable: " + firstLine(strings.TrimSpace(res.Stderr))})
		return
	case res.ExitCode != 0:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "환경 준비 먼저"})
		return
	}
	sinceText := strings.TrimSpace(res.Stdout)
	since, perr := time.Parse(time.RFC3339, sinceText)
	if perr != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("bad prepare mark %q", sinceText)})
		return
	}

	claude := s.readSessions(ctx, "claude", sinceText, since, claudeRoot, "*.jsonl", markPath, parseClaudeLine)
	codex := s.readSessions(ctx, "codex", sinceText, since, codexRoot, "rollout-*.jsonl", markPath, parseCodexLine)
	capTranscripts([]*toolTranscript{&claude, &codex})
	writeJSON(w, 200, map[string]any{
		"scenario_id": id,
		"since":       sinceText,
		"transcripts": []toolTranscript{claude, codex},
	})
}

// lineParser 는 세션 JSONL 한 줄을 발화 하나로 바꾼다. 발화가 아닌 줄은 ok=false.
type lineParser func(raw []byte) (e transcriptEntry, ok bool)

func (s *server) readSessions(ctx context.Context, tool, sinceText string, since time.Time, root, pattern, markPath string, parse lineParser) toolTranscript {
	out := toolTranscript{Tool: tool, Since: sinceText, Entries: []transcriptEntry{}}
	// 표시보다 나중에 바뀐 파일만 — 준비 전에 끝난 옛 대화를 다 읽지 않는다.
	list, err := s.runner.Run(ctx, "", "docker", "exec", s.cfg.Workstation, "find", root, "-name", pattern, "-type", "f", "-newer", markPath)
	if err != nil {
		out.Error = "could not list session files: " + err.Error()
		return out
	}
	if list.ExitCode != 0 && !strings.Contains(list.Stderr, "No such file") {
		out.Error = "could not list session files: " + firstLine(strings.TrimSpace(list.Combined()))
		return out
	}
	files := strings.Fields(list.Stdout)
	sort.Strings(files)
	var entries []transcriptEntry
	for _, f := range files {
		if strings.Contains(f, "/subagents/") {
			continue
		}
		body, err := s.runner.Run(ctx, "", "docker", "exec", s.cfg.Workstation, "cat", f)
		if err != nil || body.ExitCode != 0 {
			out.Error = fmt.Sprintf("%s: could not read", f)
			return withoutEntries(out)
		}
		got, perr := parseSessionFile(body.Stdout, parse)
		if perr != nil {
			out.Error = fmt.Sprintf("%s: %v", f, perr)
			return withoutEntries(out)
		}
		for _, e := range got {
			if !e.when.Before(since) {
				entries = append(entries, e)
			}
		}
	}
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].when.Before(entries[j].when) })
	for i := range entries {
		if len(entries[i].Text) > maxEntryBytes {
			entries[i].Text, _ = clip(entries[i].Text, maxEntryBytes)
			out.Truncated = true
		}
	}
	if entries != nil {
		out.Entries = entries
	}
	return out
}

func withoutEntries(t toolTranscript) toolTranscript {
	t.Entries = []transcriptEntry{}
	return t
}

// parseSessionFile 은 JSONL 본문을 발화 목록으로 바꾼다. 마지막 줄이 쓰다 만 것이면(개행 없이 끝나고 JSON 이
// 아님) 건너뛰고, 그 밖에 JSON 이 아닌 줄이 있으면 형식이 바뀐 것으로 보고 오류를 돌려준다.
func parseSessionFile(body string, parse lineParser) ([]transcriptEntry, error) {
	lines := strings.Split(body, "\n")
	endsWithNewline := strings.HasSuffix(body, "\n")
	var out []transcriptEntry
	for i, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !json.Valid([]byte(line)) {
			if i == len(lines)-1 && !endsWithNewline {
				continue
			}
			return nil, fmt.Errorf("line %d is not JSON", i+1)
		}
		if e, ok := parse([]byte(line)); ok {
			out = append(out, e)
		}
	}
	return out, nil
}

// capTranscripts 는 두 도구의 텍스트 합계가 상한을 넘으면 가장 오래된 발화부터 버린다. 버린 도구는 truncated.
func capTranscripts(ts []*toolTranscript) {
	type ref struct {
		t *toolTranscript
		i int
	}
	var all []ref
	total := 0
	for _, t := range ts {
		for i, e := range t.Entries {
			all = append(all, ref{t, i})
			total += len(e.Text)
		}
	}
	if total <= maxTranscriptBytes {
		return
	}
	sort.SliceStable(all, func(a, b int) bool { return all[a].t.Entries[all[a].i].when.Before(all[b].t.Entries[all[b].i].when) })
	drop := map[*toolTranscript]map[int]bool{}
	for _, r := range all {
		if total <= maxTranscriptBytes {
			break
		}
		total -= len(r.t.Entries[r.i].Text)
		if drop[r.t] == nil {
			drop[r.t] = map[int]bool{}
		}
		drop[r.t][r.i] = true
		r.t.Truncated = true
	}
	for t, idx := range drop {
		kept := make([]transcriptEntry, 0, len(t.Entries)-len(idx))
		for i, e := range t.Entries {
			if !idx[i] {
				kept = append(kept, e)
			}
		}
		t.Entries = kept
	}
}

// ---------- Claude Code ----------

// Claude Code 의 줄은 type 이 user / assistant 일 때만 발화다(attachment·system·api-request* 등은 건너뛴다).
// user 의 message.content 는 문자열(학생이 친 프롬프트)이거나 블록 목록이다 — tool_result 만 든 줄은 도구 결과다.
// assistant 는 블록 하나당 한 줄이고 type:"text" 블록만 쓴다(thinking·tool_use 제외). isSidechain(서브에이전트)·
// isMeta·isApiErrorMessage(로그인 실패 같은 합성 오류) 줄은 뺀다.
var claudeInjectedPrefixes = []string{
	"<system-reminder>", "<local-command-", "<command-name>", "<command-message>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
	"[Request interrupted",
}

func parseClaudeLine(raw []byte) (transcriptEntry, bool) {
	var l struct {
		Type              string `json:"type"`
		Timestamp         string `json:"timestamp"`
		IsSidechain       bool   `json:"isSidechain"`
		IsMeta            bool   `json:"isMeta"`
		IsAPIErrorMessage bool   `json:"isApiErrorMessage"`
		Message           struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(raw, &l) != nil || l.IsSidechain || l.IsMeta || l.IsAPIErrorMessage {
		return transcriptEntry{}, false
	}
	if (l.Type != "user" && l.Type != "assistant") || l.Message.Role != l.Type {
		return transcriptEntry{}, false
	}
	var texts []string
	var asString string
	if json.Unmarshal(l.Message.Content, &asString) == nil {
		texts = []string{asString}
	} else {
		var blocks []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(l.Message.Content, &blocks) != nil {
			return transcriptEntry{}, false
		}
		for _, b := range blocks {
			if b.Type == "text" {
				texts = append(texts, b.Text)
			}
		}
	}
	return buildEntry(l.Type, l.Timestamp, texts, claudeInjectedPrefixes)
}

// ---------- Codex ----------

// Codex rollout 의 줄은 {timestamp, type, payload} 이고 발화는 type:"response_item", payload.type:"message" 다.
// role 이 user / assistant 인 것만, content 블록 중 input_text / output_text 의 text 를 쓴다. role:"developer" 와
// reasoning·function_call*·custom_tool_call* 은 뺀다. user 로 들어오는 주입 문맥(환경 정보, AGENTS.md 안내, 중단 알림)은 뺀다.
var codexInjectedPrefixes = []string{
	"<environment_context>", "<user_instructions>", "<INSTRUCTIONS>", "# AGENTS.md instructions", "<turn_aborted>",
	"<permissions", "<skills_instructions>", "<collaboration_mode>",
}

func parseCodexLine(raw []byte) (transcriptEntry, bool) {
	var l struct {
		Type      string `json:"type"`
		Timestamp string `json:"timestamp"`
		Payload   struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"payload"`
	}
	if json.Unmarshal(raw, &l) != nil || l.Type != "response_item" || l.Payload.Type != "message" {
		return transcriptEntry{}, false
	}
	if l.Payload.Role != "user" && l.Payload.Role != "assistant" {
		return transcriptEntry{}, false
	}
	var texts []string
	for _, b := range l.Payload.Content {
		if b.Type == "input_text" || b.Type == "output_text" {
			texts = append(texts, b.Text)
		}
	}
	return buildEntry(l.Payload.Role, l.Timestamp, texts, codexInjectedPrefixes)
}

func buildEntry(role, ts string, texts []string, injected []string) (transcriptEntry, bool) {
	when, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return transcriptEntry{}, false
	}
	var kept []string
next:
	for _, t := range texts {
		trimmed := strings.TrimSpace(t)
		if trimmed == "" {
			continue
		}
		// 주입된 문맥은 사용자가 친 말이 아니다 — 어시스턴트 발화에는 적용하지 않는다.
		if role == "user" {
			for _, p := range injected {
				if strings.HasPrefix(trimmed, p) {
					continue next
				}
			}
		}
		kept = append(kept, trimmed)
	}
	if len(kept) == 0 {
		return transcriptEntry{}, false
	}
	return transcriptEntry{Role: role, At: ts, Text: strings.Join(kept, "\n"), when: when}, true
}
