package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

// /api/floci/reset — compose 가 만든 Floci 컨테이너를 같은 설정으로 다시 만들어 상태(S3·EC2…)를 비운다.
// Floci 는 데이터를 컨테이너 파일시스템에 두므로 재시작으로는 비워지지 않는다. 라벨(compose 의 project/
// service)까지 그대로 옮겨 이후 `docker compose up -d` 가 이 컨테이너를 자기 것으로 본다.
//
// 옮기는 것: 이미지, Cmd/Entrypoint, Env, Labels, 마운트(bind·named volume — Binds 와 Mounts 둘 다), 포트
// 매핑, Privileged, 재시작 정책, 네트워크와 별칭. 익명 볼륨은 상태의 일부라 버린다(rm -v).

type mountSpec struct {
	Type   string // bind | volume
	Source string
	Target string
	RO     bool
}

type containerSpec struct {
	Image         string
	Entrypoint    []string
	Cmd           []string
	Env           []string
	Labels        map[string]string
	Mounts        []mountSpec
	Ports         []string // "127.0.0.1:4566:4566/tcp" 꼴
	Privileged    bool
	RestartPolicy string
	Networks      map[string][]string // 이름 → 별칭
}

var shortIDPattern = regexp.MustCompile(`^[0-9a-f]{12}$`)

func (s *server) inspectContainer(ctx context.Context, name string) (containerSpec, error) {
	out, err := run(ctx, s.runner, "docker", "inspect", "--format", "{{json .}}", name)
	if err != nil {
		return containerSpec{}, err
	}
	var raw struct {
		Config struct {
			Image      string            `json:"Image"`
			Entrypoint []string          `json:"Entrypoint"`
			Cmd        []string          `json:"Cmd"`
			Env        []string          `json:"Env"`
			Labels     map[string]string `json:"Labels"`
		} `json:"Config"`
		HostConfig struct {
			Binds         []string `json:"Binds"`
			Privileged    bool     `json:"Privileged"`
			RestartPolicy struct {
				Name string `json:"Name"`
			} `json:"RestartPolicy"`
			PortBindings map[string][]struct {
				HostIP   string `json:"HostIp"`
				HostPort string `json:"HostPort"`
			} `json:"PortBindings"`
		} `json:"HostConfig"`
		Mounts []struct {
			Type        string `json:"Type"`
			Name        string `json:"Name"`
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
			RW          bool   `json:"RW"`
		} `json:"Mounts"`
		NetworkSettings struct {
			Networks map[string]struct {
				Aliases []string `json:"Aliases"`
			} `json:"Networks"`
		} `json:"NetworkSettings"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return containerSpec{}, fmt.Errorf("inspect: %v", err)
	}
	spec := containerSpec{
		Image:         raw.Config.Image,
		Entrypoint:    raw.Config.Entrypoint,
		Cmd:           raw.Config.Cmd,
		Env:           raw.Config.Env,
		Labels:        raw.Config.Labels,
		Privileged:    raw.HostConfig.Privileged,
		RestartPolicy: raw.HostConfig.RestartPolicy.Name,
		Networks:      map[string][]string{},
	}
	// .Mounts 가 실제 상태다(Binds 는 short 문법으로 만든 것만 든다). bind 와 이름 있는 볼륨만 옮기고,
	// 익명 볼륨(이름이 64자 hex)은 상태라 버린다.
	for _, m := range raw.Mounts {
		switch m.Type {
		case "bind":
			spec.Mounts = append(spec.Mounts, mountSpec{Type: "bind", Source: m.Source, Target: m.Destination, RO: !m.RW})
		case "volume":
			if len(m.Name) == 64 {
				continue
			}
			spec.Mounts = append(spec.Mounts, mountSpec{Type: "volume", Source: m.Name, Target: m.Destination, RO: !m.RW})
		}
	}
	sort.Slice(spec.Mounts, func(i, j int) bool { return spec.Mounts[i].Target < spec.Mounts[j].Target })
	ports := make([]string, 0)
	for containerPort, bindings := range raw.HostConfig.PortBindings {
		for _, b := range bindings {
			p := b.HostPort + ":" + containerPort
			if b.HostIP != "" {
				p = b.HostIP + ":" + p
			}
			ports = append(ports, p)
		}
	}
	sort.Strings(ports)
	spec.Ports = ports
	for n, v := range raw.NetworkSettings.Networks {
		var aliases []string
		for _, a := range v.Aliases {
			// 컨테이너 이름 자체와 옛 컨테이너의 short ID 는 새 컨테이너가 다시 얻는다 — 옮기면 죽은 이름이 남는다.
			if a == "" || a == name || shortIDPattern.MatchString(a) {
				continue
			}
			aliases = append(aliases, a)
		}
		spec.Networks[n] = aliases
	}
	return spec, nil
}

// runArgs 는 spec 대로 `docker run -d` 인자를 만든다. 첫 네트워크(이름순)만 run 에 넣고 나머지는 connect 한다.
func runArgs(name string, spec containerSpec) (args []string, extraNetworks []string) {
	args = []string{"run", "-d", "--name", name}
	if spec.RestartPolicy != "" && spec.RestartPolicy != "no" {
		args = append(args, "--restart", spec.RestartPolicy)
	}
	if spec.Privileged {
		args = append(args, "--privileged")
	}
	for _, e := range spec.Env {
		args = append(args, "-e", e)
	}
	keys := make([]string, 0, len(spec.Labels))
	for k := range spec.Labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		args = append(args, "--label", k+"="+spec.Labels[k])
	}
	for _, m := range spec.Mounts {
		opt := fmt.Sprintf("type=%s,source=%s,target=%s", m.Type, m.Source, m.Target)
		if m.RO {
			opt += ",readonly"
		}
		args = append(args, "--mount", opt)
	}
	for _, p := range spec.Ports {
		args = append(args, "-p", p)
	}
	nets := make([]string, 0, len(spec.Networks))
	for n := range spec.Networks {
		nets = append(nets, n)
	}
	sort.Strings(nets)
	if len(nets) > 0 {
		args = append(args, "--network", nets[0])
		for _, a := range spec.Networks[nets[0]] {
			args = append(args, "--network-alias", a)
		}
		extraNetworks = nets[1:]
	}
	if len(spec.Entrypoint) > 0 {
		args = append(args, "--entrypoint", spec.Entrypoint[0])
	}
	args = append(args, spec.Image)
	if len(spec.Entrypoint) > 1 {
		args = append(args, spec.Entrypoint[1:]...)
	}
	args = append(args, spec.Cmd...)
	return args, extraNetworks
}

func (s *server) handleFlociReset(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	name := s.cfg.Floci
	var st stepper
	var spec containerSpec
	ok := st.run("inspect", func() (string, error) {
		var err error
		spec, err = s.inspectContainer(ctx, name)
		if err != nil {
			return "", err
		}
		return spec.Image, nil
	})
	ok = ok && st.run("remove", func() (string, error) {
		return run(ctx, s.runner, "docker", "rm", "-f", "-v", name)
	})
	var extra []string
	ok = ok && st.run("create", func() (string, error) {
		args, extraNets := runArgs(name, spec)
		extra = extraNets
		out, err := run(ctx, s.runner, "docker", args...)
		if err != nil {
			// 옛 컨테이너는 이미 지워졌다 — 복구 방법을 결과에 남긴다.
			return out + "\n복구: compose 폴더에서 `docker compose up -d floci`", err
		}
		return "created " + firstLine(out), nil
	})
	for _, n := range extra {
		net := n
		ok = ok && st.run("connect-"+net, func() (string, error) {
			return run(ctx, s.runner, "docker", "network", "connect", net, name)
		})
	}
	ok = ok && st.run("wait-ready", func() (string, error) {
		// Floci 자신의 healthcheck 를 본다 — workstation 이 내려가 있어도 Floci 준비 여부는 알 수 있다.
		deadline := time.Now().Add(90 * time.Second)
		for time.Now().Before(deadline) {
			state, _ := run(ctx, s.runner, "docker", "inspect", "-f", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}", name)
			fields := strings.Fields(state)
			if len(fields) >= 1 && fields[0] == "running" && (len(fields) == 1 || fields[1] == "healthy") {
				return strings.Join(fields, " "), nil
			}
			if len(fields) >= 1 && (fields[0] == "exited" || fields[0] == "dead") {
				return "", fmt.Errorf("%s is %s", name, fields[0])
			}
			select {
			case <-ctx.Done():
				return "", ctx.Err()
			case <-time.After(2 * time.Second):
			}
		}
		return "", fmt.Errorf("timeout waiting for %s", name)
	})
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": st.steps})
}
