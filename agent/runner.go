package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Result 는 외부 명령 하나의 결과다. 증거로 쓸 때는 Combined(), 다음 명령의 입력으로 쓸 때는
// Stdout 만 쓴다 — kind 가 stderr 에 내는 경고가 kubeconfig 에 섞이면 안 된다.
type Result struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Combined 는 stdout 뒤에 stderr 를 이어 붙인 것이다.
func (r Result) Combined() string {
	if r.Stderr == "" {
		return r.Stdout
	}
	if r.Stdout == "" {
		return r.Stderr
	}
	return r.Stdout + "\n" + r.Stderr
}

// Runner 는 docker·kind 같은 외부 프로세스를 돌리는 경계다. 핸들러는 이 인터페이스만 보고,
// 시험은 가짜를 끼운다. 명령이 0 이 아닌 코드로 끝난 것은 오류가 아니라 Result.ExitCode 로
// 돌려준다 — 오류는 명령을 띄우지 못했거나 컨텍스트가 끝난 경우만이다.
type Runner interface {
	Run(ctx context.Context, stdin, name string, args ...string) (Result, error)
}

type execRunner struct{}

func (execRunner) Run(ctx context.Context, stdin, name string, args ...string) (Result, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	// 컨텍스트가 끝나 부모를 죽인 뒤에도 손자(kind 가 띄운 docker)가 파이프를 쥐고 있으면
	// 출력 수집이 영원히 막힌다 — WaitDelay 가 그 파이프를 끊는다.
	cmd.WaitDelay = 5 * time.Second
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	res := Result{Stdout: stdout.String(), Stderr: stderr.String()}
	if err == nil {
		return res, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		res.ExitCode = exitErr.ExitCode()
		if ctx.Err() != nil {
			return res, ctx.Err()
		}
		return res, nil
	}
	return res, err
}

// run 은 결과를 「stdout 문자열 + 오류」 꼴로 쓰는 호출자용 편의 함수다. 0 이 아닌 exit 는 오류이고
// 그때의 문자열은 stderr 까지 합친 것이다.
func run(ctx context.Context, r Runner, name string, args ...string) (string, error) {
	return runInput(ctx, r, "", name, args...)
}

func runInput(ctx context.Context, r Runner, stdin, name string, args ...string) (string, error) {
	res, err := r.Run(ctx, stdin, name, args...)
	if err != nil {
		return strings.TrimSpace(res.Combined()), err
	}
	if res.ExitCode != 0 {
		out := strings.TrimSpace(res.Combined())
		return out, fmt.Errorf("%s exited %d: %s", name, res.ExitCode, firstLine(out))
	}
	return strings.TrimSpace(res.Stdout), nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
