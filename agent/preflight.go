package main

import (
	"context"
	"net/http"
	"strings"
	"time"
)

// 응시 전 점검(#78) — 지원자 PC 의 Docker 가 실습을 돌릴 수 있는 상태인지 세 항목으로 본다.
// 시험 응시 화면은 하나라도 실패하면 「시작」을 막고, 연습 화면은 경고만 보인다(web/src/exam.ts preflightGate).

const (
	helpEngine     = "https://docs.docker.com/desktop/"
	helpLinuxMode  = "https://docs.docker.com/desktop/troubleshoot-and-support/faqs/windowsfaqs/"
	helpPermission = "https://docs.docker.com/engine/install/linux-postinstall/"
)

// preflightTimeout 은 docker 명령 하나의 상한이다 — 멈춘 엔진이 화면을 붙잡지 않게.
const preflightTimeout = 10 * time.Second

type preflightCheck struct {
	ID      string `json:"id"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	HelpURL string `json:"help_url"`
}

type preflightResult struct {
	OK     bool             `json:"ok"`
	Checks []preflightCheck `json:"checks"`
}

// preflight 는 engine·linux_mode·permission 을 이 순서로 돌려준다. 엔진에 닿지 못하면(꺼짐·권한)
// 뒤 항목은 확인할 수 없으므로 원인 항목을 가리키는 실패로 남긴다 — 통과로 보이면 안 된다.
func (s *server) preflight(ctx context.Context) preflightResult {
	engine := preflightCheck{ID: "engine"}
	linux := preflightCheck{ID: "linux_mode"}
	perm := preflightCheck{ID: "permission"}

	vctx, cancel := context.WithTimeout(ctx, preflightTimeout)
	out, err := run(vctx, s.runner, "docker", "version", "--format", "{{.Server.Version}}")
	cancel()
	switch {
	case err != nil && strings.Contains(strings.ToLower(out), "permission denied"):
		perm.Message = "docker 에 접근할 권한이 없다 — 사용자를 docker 그룹에 넣거나 Docker Desktop 을 다시 시작한다"
		perm.HelpURL = helpPermission
		engine.Message = "권한 문제로 Docker 엔진을 확인하지 못했다 — permission 항목을 먼저 해결한다"
		engine.HelpURL = helpPermission
		linux.Message = "권한 문제로 컨테이너 모드를 확인하지 못했다 — permission 항목을 먼저 해결한다"
		linux.HelpURL = helpPermission
	case err != nil:
		engine.Message = "Docker 엔진에 닿지 않는다 — Docker Desktop 을 설치하고 켠다"
		engine.HelpURL = helpEngine
		linux.Message = "엔진이 꺼져 있어 컨테이너 모드를 확인하지 못했다 — engine 항목을 먼저 해결한다"
		linux.HelpURL = helpEngine
		perm.Message = "엔진이 꺼져 있어 권한을 확인하지 못했다 — engine 항목을 먼저 해결한다"
		perm.HelpURL = helpEngine
	default:
		engine.OK, engine.Message = true, "Docker 엔진이 돈다 ("+firstLine(out)+")"
		perm.OK, perm.Message = true, "docker 에 접근할 권한이 있다"
		ictx, cancel := context.WithTimeout(ctx, preflightTimeout)
		osType, err := run(ictx, s.runner, "docker", "info", "--format", "{{.OSType}}")
		cancel()
		osType = strings.ToLower(strings.TrimSpace(firstLine(osType)))
		switch {
		case err != nil:
			linux.Message = "컨테이너 모드를 확인하지 못했다 — Docker Desktop 을 다시 시작한다"
			linux.HelpURL = helpLinuxMode
		case osType != "linux":
			linux.Message = "Linux 컨테이너 모드가 아니다(OSType=" + osType + ") — Docker Desktop 메뉴에서 「Switch to Linux containers」로 바꾼다"
			linux.HelpURL = helpLinuxMode
		default:
			linux.OK, linux.Message = true, "Linux 컨테이너 모드다"
		}
	}

	checks := []preflightCheck{engine, linux, perm}
	ok := true
	for _, c := range checks {
		ok = ok && c.OK
	}
	return preflightResult{OK: ok, Checks: checks}
}

func (s *server) handlePreflight(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.preflight(r.Context()))
}
