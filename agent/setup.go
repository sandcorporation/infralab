package main

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// prepareMarkPath — 시나리오 준비 표시 파일. 있으면 준비됨(채점 잠금 풀림), 본문은 준비 시각(UTC).
func prepareMarkPath(scenarioID string) string {
	return prepareMarkDir + "/" + scenarioID + ".prepared"
}

// /api/setup — 「환경 준비」. 브라우저가 서버의 준비 응답을 넘기면 한 번에
//
//  1. Floci 재생성 (reset.floci)
//  2. kind 재생성 — 클러스터가 이미 맞게 있어도 지우고 다시 만든다 (reset.kind)
//  3. 규칙 파일 쓰기 — /work/CLAUDE.md 와 /work/AGENTS.md 에 같은 본문
//  4. 준비 표시 — /work/.infralab/<scenario_id>.prepared 에 UTC 시각
//  5. setup 실행 (있으면) — 검사와 같은 실행기
//
// 을 하고 단계별 결과와 ok 를 돌려준다. 앞 단계가 실패하면 뒤는 돌리지 않는다.
//
// 요청: {"scenario_id", "reset": {"floci": bool, "kind": {control_planes, workers}|null},
//        "setup": {command, scripts, timeout_seconds}|null, "ai_rules": "본문"}

const (
	maxRulesBytes = 64 * 1024
	// 준비 표시는 준비한 결과(/work)와 같은 자리에 둔다. 홈(/root)은 기수마다 다른 compose 폴더가 같은 볼륨
	// (infralab_home)을 이어 쓰므로, 거기 두면 다른 기수 폴더의 빈 /work 에서도 「준비됨」이 된다(#124).
	prepareMarkDir   = "/work/.infralab"
	rulesDirInWorkst = "/work"
)

var scenarioIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

type setupRequest struct {
	ScenarioID string `json:"scenario_id"`
	Reset      struct {
		Floci bool `json:"floci"`
		Kind  *struct {
			ControlPlanes int `json:"control_planes"`
			Workers       int `json:"workers"`
		} `json:"kind"`
	} `json:"reset"`
	Setup *struct {
		Command        string            `json:"command"`
		Scripts        map[string]string `json:"scripts"`
		TimeoutSeconds int               `json:"timeout_seconds"`
	} `json:"setup"`
	AIRules string `json:"ai_rules"`
}

func (r *setupRequest) validate() error {
	if !scenarioIDPattern.MatchString(r.ScenarioID) {
		return fmt.Errorf("scenario_id must be lowercase letters, digits and hyphens")
	}
	if len(r.AIRules) > maxRulesBytes {
		return fmt.Errorf("ai_rules is too large (max %d bytes)", maxRulesBytes)
	}
	if k := r.Reset.Kind; k != nil {
		if k.ControlPlanes <= 0 {
			k.ControlPlanes = 1
		}
		if k.ControlPlanes > maxControlPlanes || k.Workers < 0 || k.Workers > maxWorkers {
			return fmt.Errorf("reset.kind: control_planes must be 1..%d and workers 0..%d", maxControlPlanes, maxWorkers)
		}
	}
	if st := r.Setup; st != nil {
		if strings.TrimSpace(st.Command) == "" {
			return fmt.Errorf("setup.command is required")
		}
		if st.TimeoutSeconds < 0 || st.TimeoutSeconds > int(maxCheckTimeout.Seconds()) {
			return fmt.Errorf("setup.timeout_seconds must be 1..%d", int(maxCheckTimeout.Seconds()))
		}
		if err := validateScripts(st.Scripts); err != nil {
			return err
		}
	}
	return nil
}

func (s *server) handleSetup(w http.ResponseWriter, r *http.Request) {
	var req setupRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json: " + err.Error()})
		return
	}
	if err := req.validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	// 규칙 파일·표시·setup 이 모두 workstation 안에서 일어난다 — 없으면 아무것도 건드리지 않고 알린다.
	if state := s.containerState(r.Context(), s.cfg.Workstation); state != "running" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error":       "workstation is not running",
			"workstation": state,
		})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Minute)
	defer cancel()

	// 이전 준비의 표시는 이 준비가 끝나기 전까지 무효다 — 중간에 실패하면 옛 표시가 채점을 열어 두지 않게 먼저 지운다.
	markPath := prepareMarkPath(req.ScenarioID)
	_, _ = run(ctx, s.runner, "docker", "exec", s.cfg.Workstation, "rm", "-f", markPath)

	var st stepper
	ok := true
	if req.Reset.Floci {
		st.prefix = "floci/"
		ok = s.flociReset(ctx, &st)
	}
	if ok && req.Reset.Kind != nil {
		st.prefix = "kind/"
		ok = s.kindUp(ctx, &st, req.Reset.Kind.ControlPlanes, req.Reset.Kind.Workers, true)
	}
	st.prefix = ""
	ok = ok && st.run("rules", func() (string, error) {
		for _, name := range []string{"CLAUDE.md", "AGENTS.md"} {
			wctx, cancel := context.WithTimeout(ctx, defaultCheckTimeout)
			err := s.writeWorkstationFile(wctx, rulesDirInWorkst+"/"+name, req.AIRules, false)
			cancel()
			if err != nil {
				return "", fmt.Errorf("%s: %w", name, err)
			}
		}
		return fmt.Sprintf("CLAUDE.md, AGENTS.md (%d bytes)", len(req.AIRules)), nil
	})
	if ok && req.Setup != nil {
		ok = st.run("setup", func() (string, error) {
			return s.runSetup(ctx, req.Setup.Command, req.Setup.Scripts, req.Setup.TimeoutSeconds)
		})
	}
	// 준비 표시는 모든 단계가 성공한 뒤에만 쓴다 — setup 이 실패했는데 채점이 열리면 안 된다.
	ok = ok && st.run("mark", func() (string, error) {
		stamp := time.Now().UTC().Format("2006-01-02T15:04:05Z")
		wctx, cancel := context.WithTimeout(ctx, defaultCheckTimeout)
		defer cancel()
		if err := s.writeWorkstationFile(wctx, markPath, stamp+"\n", false); err != nil {
			return "", err
		}
		return stamp, nil
	})
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": st.steps})
}

// runSetup 은 setup 명령을 검사와 같은 실행기로 돌린다. 비정상 종료·시간 초과는 오류이고, 출력은 오류 쪽에도 남는다.
func (s *server) runSetup(ctx context.Context, command string, scripts map[string]string, timeoutSeconds int) (string, error) {
	scriptDir := scriptRootInWorkstation + "/" + nonce()
	if len(scripts) > 0 {
		if err := s.installScripts(ctx, scriptDir, scripts); err != nil {
			return "", fmt.Errorf("could not install scripts into workstation: %w", err)
		}
		defer s.removeScripts(scriptDir)
	}
	timeout := clampTimeout(timeoutSeconds)
	res, errMsg, _ := s.execInWorkstation(ctx, command, scriptDir, timeout)
	out, _ := clip(res.Combined(), maxOutputBytes)
	switch {
	case errMsg != "":
		return out, fmt.Errorf("%s", errMsg)
	case res.ExitCode != 0:
		return out, fmt.Errorf("setup exited %d", res.ExitCode)
	}
	return out, nil
}
