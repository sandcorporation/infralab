package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// 학생 PC 에서 올릴 수 있는 노드 수의 상한. kindest/node 하나가 수백 MB 다.
const (
	maxControlPlanes = 3
	maxWorkers       = 5
)

// handleKindUp 은 노드 구성대로 kind 클러스터를 만들고 kubeconfig 를 workstation 에 넣고
// workstation 을 kind 네트워크에 붙인다. 클러스터가 이미 있고 노드 수가 같으면 만들기는 건너뛰고 나머지만
// 한다(에이전트 재기동 뒤 복구 — PoC 에서 검증). 노드 수가 다르면 지우고 다시 만든다 — 「올리기」를 눌렀는데
// 환경이 계속 「빠진 것: kind」로 남는 일이 없게.
func (s *server) handleKindUp(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ControlPlanes int `json:"control_planes"`
		Workers       int `json:"workers"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json: " + err.Error()})
		return
	}
	if req.ControlPlanes <= 0 {
		req.ControlPlanes = 1
	}
	if req.ControlPlanes > maxControlPlanes || req.Workers < 0 || req.Workers > maxWorkers {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": fmt.Sprintf("control_planes must be 1..%d and workers 0..%d", maxControlPlanes, maxWorkers),
		})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()

	want := req.ControlPlanes + req.Workers
	var st stepper
	ok := st.run("create", func() (string, error) {
		if out, _ := run(ctx, s.runner, "kind", "get", "clusters"); containsLine(out, s.cfg.KindCluster) {
			if have := len(s.kindNodes(ctx)); have == want {
				return "exists", nil
			} else {
				if out, err := run(ctx, s.runner, "kind", "delete", "cluster", "--name", s.cfg.KindCluster); err != nil {
					return out, fmt.Errorf("cluster has %d nodes, want %d; delete failed: %w", have, want, err)
				}
			}
		}
		cfg := "kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n"
		cfg += strings.Repeat("  - role: control-plane\n", req.ControlPlanes)
		cfg += strings.Repeat("  - role: worker\n", req.Workers)
		return runInput(ctx, s.runner, cfg, "kind", "create", "cluster", "--name", s.cfg.KindCluster, "--config", "-", "--wait", "180s")
	})
	ok = ok && st.run("kubeconfig-into-workstation", func() (string, error) {
		// stdout 만 쓴다 — kind 의 stderr 경고가 kubeconfig 에 섞이면 kubectl 이 YAML 을 못 읽는다.
		kc, err := run(ctx, s.runner, "kind", "get", "kubeconfig", "--name", s.cfg.KindCluster, "--internal")
		if err != nil {
			return kc, err
		}
		if err := s.writeWorkstationFile(ctx, "/root/.kube/config", kc+"\n", false); err != nil {
			return "", err
		}
		return fmt.Sprintf("written (%d bytes)", len(kc)+1), nil
	})
	ok = ok && st.run("join-kind-network", func() (string, error) {
		members, _ := run(ctx, s.runner, "docker", "network", "inspect", "kind", "-f", "{{range .Containers}}{{.Name}} {{end}}")
		for _, m := range strings.Fields(members) {
			if m == s.cfg.Workstation {
				return "already connected", nil
			}
		}
		out, err := run(ctx, s.runner, "docker", "network", "connect", "kind", s.cfg.Workstation)
		if err != nil && strings.Contains(out, "already exists") {
			return "already connected", nil
		}
		if err != nil {
			return out, err
		}
		return "connected", nil
	})
	ok = ok && st.run("verify", func() (string, error) {
		return run(ctx, s.runner, "docker", "exec", s.cfg.Workstation, "kubectl", "get", "nodes", "-o", "wide")
	})
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": st.steps})
}

func (s *server) handleKindDown(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	var st stepper
	ok := st.run("delete", func() (string, error) {
		return run(ctx, s.runner, "kind", "delete", "cluster", "--name", s.cfg.KindCluster)
	})
	writeJSON(w, 200, map[string]any{"ok": ok, "steps": st.steps})
}

func containsLine(out, want string) bool {
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimSpace(l) == want {
			return true
		}
	}
	return false
}
