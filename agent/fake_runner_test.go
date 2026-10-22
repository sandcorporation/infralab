package main

import (
	"context"
	"strings"
	"sync"
)

// fakeRunner 는 외부 프로세스 경계를 대신한다. 명령 문자열(이름 + 인자를 공백으로 이은 것)의
// 접두로 응답을 정하고, 넘어온 호출을 전부 기록한다. 응답이 없는 명령은 빈 출력·exit 0 이다.
type fakeRunner struct {
	mu        sync.Mutex
	responses []fakeResponse
	calls     []call
	// onCall 은 호출마다 잠금 밖에서 불린다 — 시험이 명령을 붙잡아 두는 데 쓴다.
	onCall func(call)
}

type fakeResponse struct {
	prefix string
	res    Result
}

type call struct {
	Name  string
	Args  []string
	Stdin string
}

func (c call) String() string { return strings.Join(append([]string{c.Name}, c.Args...), " ") }

func newFakeRunner() *fakeRunner { return &fakeRunner{} }

// respond 는 stdout 과 exit 코드로 응답을 등록한다.
func (f *fakeRunner) respond(prefix, stdout string, code int) {
	f.respondFull(prefix, Result{Stdout: stdout, ExitCode: code})
}

func (f *fakeRunner) respondFull(prefix string, res Result) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.responses = append(f.responses, fakeResponse{prefix, res})
}

func (f *fakeRunner) Run(_ context.Context, stdin, name string, args ...string) (Result, error) {
	c := call{name, args, stdin}
	f.mu.Lock()
	f.calls = append(f.calls, c)
	hook := f.onCall
	s := c.String()
	var res Result
	// 뒤에 등록한 응답이 우선한다 — 시험 안에서 상태 변화를 흉내 낼 수 있게.
	for i := len(f.responses) - 1; i >= 0; i-- {
		if strings.HasPrefix(s, f.responses[i].prefix) {
			res = f.responses[i].res
			break
		}
	}
	f.mu.Unlock()
	if hook != nil {
		hook(c)
	}
	return res, nil
}

// callsWithPrefix 는 기록된 호출 중 명령 문자열이 prefix 로 시작하는 것을 돌려준다.
func (f *fakeRunner) callsWithPrefix(prefix string) []call {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []call
	for _, c := range f.calls {
		if strings.HasPrefix(c.String(), prefix) {
			out = append(out, c)
		}
	}
	return out
}
