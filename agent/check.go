package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// /api/check — 서버가 정의한 검사(명령 + 기대값) 목록을 받아 workstation 에서 돌리고 검사별
// pass/fail·원시 출력·소요 시간을 돌려준다. 에이전트는 서버를 모른다 — 결과는 응답으로만 간다.
//
// 요청: {"checks": [{id, name, hint, command, timeout_seconds, expect: {type, ...}}], "scripts": {"name": "본문"}}
// expect.type: exit_zero | equals{value} | contains{value} | regex{pattern} | jsonpath{path, equals|min|contains}

const (
	maxChecksPerRequest  = 50
	maxScriptsPerRequest = 20
	maxOutputBytes       = 8 * 1024
	maxScriptBytes       = 64 * 1024
	defaultCheckTimeout  = 30 * time.Second
	maxCheckTimeout      = 300 * time.Second
	// 보조 스크립트는 요청마다 새 하위 디렉터리에 들어가고 끝나면 지워진다 — 다른 시나리오의 같은 이름
	// 스크립트가 섞이거나 옛 것이 남아 통과시키는 일을 막는다.
	scriptRootInWorkstation = "/opt/infralab/checks"
)

type checkDef struct {
	ID             string          `json:"id"`
	Name           string          `json:"name"`
	Hint           string          `json:"hint"`
	Command        string          `json:"command"`
	TimeoutSeconds int             `json:"timeout_seconds"`
	Expect         json.RawMessage `json:"expect"`
}

type checkRequest struct {
	Checks  []checkDef        `json:"checks"`
	Scripts map[string]string `json:"scripts"`
}

type checkResult struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Hint      string `json:"hint"`
	Pass      bool   `json:"pass"`
	Output    string `json:"output"`
	Truncated bool   `json:"truncated"`
	ExitCode  int    `json:"exit_code"`
	Ms        int64  `json:"ms"`
	// Error 는 「학생이 틀렸다」가 아니라 「판정할 수 없었다」다 — 시간 초과, 환경 장애, JSON 아님.
	Error string `json:"error,omitempty"`
}

// expectation 은 파싱·검증을 마친 기대값이다. 평가는 docker 와 무관한 순수 함수다.
type expectation struct {
	Type     string
	Value    string // equals / contains
	Pattern  *regexp.Regexp
	Path     []pathSegment
	JSONPred string // equals / min / contains
	JSONText string // equals / contains 의 값
	Min      float64
}

type pathSegment struct {
	Key   string
	Index int // Key 가 "" 이면 배열 인덱스
}

var scriptNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$`)

// ---------- 파싱 ----------

func parseExpect(raw json.RawMessage) (expectation, error) {
	var m struct {
		Type     string       `json:"type"`
		Value    *string      `json:"value"`
		Pattern  *string      `json:"pattern"`
		Path     *string      `json:"path"`
		Equals   *string      `json:"equals"`
		Contains *string      `json:"contains"`
		Min      *json.Number `json:"min"`
	}
	if len(raw) == 0 {
		return expectation{}, errors.New("expect is required")
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		return expectation{}, fmt.Errorf("expect is not an object: %v", err)
	}
	e := expectation{Type: m.Type}
	switch m.Type {
	case "exit_zero":
		return e, nil
	case "equals", "contains":
		if m.Value == nil {
			return e, fmt.Errorf("expect.%s needs value", m.Type)
		}
		e.Value = *m.Value
		return e, nil
	case "regex":
		if m.Pattern == nil {
			return e, errors.New("expect.regex needs pattern")
		}
		re, err := regexp.Compile(*m.Pattern)
		if err != nil {
			return e, fmt.Errorf("expect.regex: %v", err)
		}
		e.Pattern = re
		return e, nil
	case "jsonpath":
		if m.Path == nil {
			return e, errors.New("expect.jsonpath needs path")
		}
		segs, err := parsePath(*m.Path)
		if err != nil {
			return e, err
		}
		e.Path = segs
		n := 0
		if m.Equals != nil {
			n++
			e.JSONPred, e.JSONText = "equals", *m.Equals
		}
		if m.Contains != nil {
			n++
			e.JSONPred, e.JSONText = "contains", *m.Contains
		}
		if m.Min != nil {
			n++
			f, err := m.Min.Float64()
			if err != nil {
				return e, errors.New("expect.jsonpath.min must be a number")
			}
			e.JSONPred, e.Min = "min", f
		}
		if n != 1 {
			return e, errors.New("expect.jsonpath needs exactly one of equals, min, contains")
		}
		return e, nil
	default:
		return e, fmt.Errorf("unknown expect type %q", m.Type)
	}
}

// parsePath 는 `.a.b[0].c` 를 조각으로 나눈다 — 서버 로더(JSONPATH_PATTERN)와 같은 문법만 받는다.
func parsePath(p string) ([]pathSegment, error) {
	if p == "" || p[0] != '.' {
		return nil, fmt.Errorf("expect.jsonpath.path must start with '.' (%q)", p)
	}
	var segs []pathSegment
	for _, part := range strings.Split(p[1:], ".") {
		if part == "" {
			return nil, fmt.Errorf("expect.jsonpath.path has an empty segment (%q)", p)
		}
		key := part
		var idx []int
		for strings.HasSuffix(key, "]") {
			open := strings.LastIndexByte(key, '[')
			if open < 0 {
				return nil, fmt.Errorf("expect.jsonpath.path has a bad index (%q)", p)
			}
			n, err := strconv.Atoi(key[open+1 : len(key)-1])
			if err != nil || n < 0 {
				return nil, fmt.Errorf("expect.jsonpath.path has a bad index (%q)", p)
			}
			idx = append([]int{n}, idx...)
			key = key[:open]
		}
		if key == "" {
			return nil, fmt.Errorf("expect.jsonpath.path has an empty key (%q)", p)
		}
		segs = append(segs, pathSegment{Key: key})
		for _, n := range idx {
			segs = append(segs, pathSegment{Index: n})
		}
	}
	return segs, nil
}

// ---------- 평가 (순수 함수) ----------

// evaluate 는 명령 결과가 기대값을 만족하는지 본다. 두 번째 값은 「판정 불가」 사유다(JSON 아님 등).
func evaluate(e expectation, res Result) (bool, string) {
	out := strings.TrimSpace(res.Stdout)
	switch e.Type {
	case "exit_zero":
		return res.ExitCode == 0, ""
	case "equals":
		return out == strings.TrimSpace(e.Value), ""
	case "contains":
		return strings.Contains(res.Stdout, e.Value), ""
	case "regex":
		return e.Pattern.MatchString(res.Stdout), ""
	case "jsonpath":
		var doc any
		dec := json.NewDecoder(strings.NewReader(res.Stdout))
		dec.UseNumber()
		if err := dec.Decode(&doc); err != nil {
			return false, "output is not JSON"
		}
		if dec.More() {
			return false, "output has more than one JSON value"
		}
		v, ok := walk(doc, e.Path)
		if !ok {
			return false, "path not found in output"
		}
		switch e.JSONPred {
		case "equals":
			return jsonText(v) == e.JSONText, ""
		case "contains":
			switch t := v.(type) {
			case []any:
				for _, item := range t {
					if jsonText(item) == e.JSONText {
						return true, ""
					}
				}
				return false, ""
			default:
				return strings.Contains(jsonText(v), e.JSONText), ""
			}
		case "min":
			n, ok := v.(json.Number)
			if !ok {
				return false, "value at path is not a number"
			}
			f, err := n.Float64()
			if err != nil {
				return false, "value at path is not a number"
			}
			return f >= e.Min, ""
		}
	}
	return false, "unknown expectation"
}

func walk(doc any, path []pathSegment) (any, bool) {
	cur := doc
	for _, s := range path {
		if s.Key != "" {
			m, ok := cur.(map[string]any)
			if !ok {
				return nil, false
			}
			cur, ok = m[s.Key]
			if !ok {
				return nil, false
			}
			continue
		}
		arr, ok := cur.([]any)
		if !ok || s.Index >= len(arr) {
			return nil, false
		}
		cur = arr[s.Index]
	}
	return cur, true
}

// jsonText 는 스칼라를 문자열로 — 기대값은 서버가 문자열로 정규화해 보낸다.
func jsonText(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case json.Number:
		return t.String()
	case bool:
		return strconv.FormatBool(t)
	default:
		b, _ := json.Marshal(t)
		return string(b)
	}
}

// ---------- 핸들러 ----------

func (s *server) handleCheck(w http.ResponseWriter, r *http.Request) {
	var req checkRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json: " + err.Error()})
		return
	}
	if len(req.Checks) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "checks is empty"})
		return
	}
	if len(req.Checks) > maxChecksPerRequest {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("too many checks (max %d)", maxChecksPerRequest)})
		return
	}
	// 하나라도 틀리면 아무것도 돌리지 않는다 — 반쯤 돈 채점은 증거가 되지 못한다.
	expects := make([]expectation, len(req.Checks))
	for i, c := range req.Checks {
		if strings.TrimSpace(c.ID) == "" || strings.TrimSpace(c.Command) == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("checks[%d]: id and command are required", i)})
			return
		}
		e, err := parseExpect(c.Expect)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("checks[%d] (%s): %v", i, c.ID, err)})
			return
		}
		expects[i] = e
	}
	if err := validateScripts(req.Scripts); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}

	ctx := r.Context()
	// 환경이 없으면 「전부 실패」가 아니라 「채점할 수 없다」다 — 화면이 설치 안내로 보내게.
	if state := s.containerState(ctx, s.cfg.Workstation); state != "running" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error":       "workstation is not running",
			"workstation": state,
		})
		return
	}

	scriptDir := scriptRootInWorkstation + "/" + nonce()
	if len(req.Scripts) > 0 {
		if err := s.installScripts(ctx, scriptDir, req.Scripts); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "could not install scripts into workstation: " + err.Error()})
			return
		}
		defer s.removeScripts(scriptDir)
	}

	results := make([]checkResult, 0, len(req.Checks))
	passed := 0
	for i, c := range req.Checks {
		res := s.runCheck(ctx, c, expects[i], scriptDir)
		if res.Pass {
			passed++
		}
		results = append(results, res)
	}
	writeJSON(w, 200, map[string]any{
		"agent_version": version,
		"passed":        passed,
		"total":         len(results),
		"results":       results,
	})
}

// validateScripts 는 보조 스크립트 묶음(개수·이름 패턴·크기)을 검사한다 — /api/check 와 /api/setup 이 같이 쓴다.
func validateScripts(scripts map[string]string) error {
	if len(scripts) > maxScriptsPerRequest {
		return fmt.Errorf("too many scripts (max %d)", maxScriptsPerRequest)
	}
	for name, body := range scripts {
		if !scriptNamePattern.MatchString(name) {
			return fmt.Errorf("scripts: bad name %q", name)
		}
		if len(body) > maxScriptBytes {
			return fmt.Errorf("scripts: %s is too large", name)
		}
	}
	return nil
}

func nonce() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// installScripts 는 보조 스크립트를 workstation 의 요청별 디렉터리에 넣는다. 검사 명령은 그 디렉터리가
// PATH 에 있는 셸에서 돌아 `bash check-nginx.sh` 든 `check-nginx.sh` 든 찾는다.
func (s *server) installScripts(ctx context.Context, dir string, scripts map[string]string) error {
	for name, body := range scripts {
		ictx, cancel := context.WithTimeout(ctx, defaultCheckTimeout)
		err := s.writeWorkstationFile(ictx, dir+"/"+name, body, true)
		cancel()
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}

func (s *server) removeScripts(dir string) {
	ctx, cancel := context.WithTimeout(context.Background(), defaultCheckTimeout)
	defer cancel()
	_, _ = run(ctx, s.runner, "docker", "exec", s.cfg.Workstation, "rm", "-rf", dir)
}

// 도커 자체가 실패했을 때의 exit 코드 — 컨테이너 없음·명령 못 찾음·실행 불가. 학생의 틀림이 아니다.
func dockerLevelFailure(res Result) bool {
	switch res.ExitCode {
	case 125, 126, 127:
		return true
	}
	return strings.Contains(res.Stderr, "Error response from daemon") ||
		strings.Contains(res.Stderr, "Cannot connect to the Docker daemon")
}

// clampTimeout 은 초 단위 시간 상한을 검사와 setup 이 같은 규칙(기본 30초, 최대 300초)으로 정한다.
func clampTimeout(seconds int) time.Duration {
	if seconds <= 0 {
		return defaultCheckTimeout
	}
	if t := time.Duration(seconds) * time.Second; t < maxCheckTimeout {
		return t
	}
	return maxCheckTimeout
}

// execInWorkstation 은 명령 하나를 workstation 의 /work 에서 돌린다 — 검사와 setup 이 같은 실행기를 쓴다.
// errMsg 가 비어 있지 않으면 「판정할 수 없었다」(시간 초과·도커 장애)이고 res 의 exit 코드는 믿지 않는다.
func (s *server) execInWorkstation(ctx context.Context, command, scriptDir string, timeout time.Duration) (res Result, errMsg string, ms int64) {
	// docker exec 클라이언트가 죽어도 컨테이너 안의 명령은 계속 돈다 — 안쪽에서도 timeout 으로 끊는다.
	// 명령은 환경변수로 넘겨 셸 인용 문제를 피한다. 로그인 셸(-l)은 쓰지 않는다 — profile 이 찍는
	// 출력이 equals/regex 판정을 더럽힌다.
	cctx, cancel := context.WithTimeout(ctx, timeout+2*time.Second)
	defer cancel()
	shell := fmt.Sprintf("export PATH=%s:$PATH; timeout %d bash -c \"$INFRALAB_CMD\"", scriptDir, int(timeout.Seconds()))

	start := time.Now()
	res, err := s.runner.Run(cctx, "", "docker", "exec", "-w", "/work", "-e", "INFRALAB_CMD="+command,
		s.cfg.Workstation, "bash", "-c", shell)
	ms = time.Since(start).Milliseconds()
	switch {
	case err != nil && (errors.Is(err, context.DeadlineExceeded) || errors.Is(cctx.Err(), context.DeadlineExceeded)):
		errMsg = fmt.Sprintf("timed out after %s", timeout)
	case err != nil:
		errMsg = "could not run: " + err.Error()
	case res.ExitCode == 124: // busybox/coreutils timeout 의 종료 코드
		errMsg = fmt.Sprintf("timed out after %s", timeout)
	case dockerLevelFailure(res):
		errMsg = "workstation unavailable: " + firstLine(strings.TrimSpace(res.Stderr))
	}
	return res, errMsg, ms
}

func (s *server) runCheck(ctx context.Context, c checkDef, e expectation, scriptDir string) checkResult {
	res, errMsg, ms := s.execInWorkstation(ctx, c.Command, scriptDir, clampTimeout(c.TimeoutSeconds))
	out := checkResult{ID: c.ID, Name: c.Name, Hint: c.Hint, ExitCode: res.ExitCode, Ms: ms}
	out.Output, out.Truncated = clip(res.Combined(), maxOutputBytes)
	if errMsg != "" {
		out.Error = errMsg
		return out
	}
	pass, why := evaluate(e, res)
	out.Pass = pass
	if !pass && why != "" {
		out.Error = why
	}
	return out
}

func clip(s string, max int) (string, bool) {
	if len(s) <= max {
		return s, false
	}
	// 바이트 경계를 UTF-8 글자 경계로 물린다.
	cut := max
	for cut > 0 && cut < len(s) && (s[cut]&0xC0) == 0x80 {
		cut--
	}
	return s[:cut] + "\n…(truncated)", true
}
