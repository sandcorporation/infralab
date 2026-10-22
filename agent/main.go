// infra-agent — 학생 로컬 Docker 를 docker.sock 으로 제어하는 에이전트.
// compose 가 올린 workstation·Floci 를 찾고, kind 클러스터를 올리고 내리며, 브라우저 터미널을
// docker exec 로 중계한다. 127.0.0.1 바인딩은 compose 의 포트 매핑이 한다. 서버는 모른다 —
// 브라우저가 중간에서 옮긴다.
package main

import (
	"log"
	"net/http"
	"os"
	"strings"
)

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	cfg := config{
		Token:          os.Getenv("AGENT_TOKEN"),
		AllowedOrigins: strings.Split(getenv("AGENT_ALLOWED_ORIGINS", "http://127.0.0.1:5173,http://localhost:5173"), ","),
		Workstation:    getenv("WORKSTATION_CONTAINER", "infralab-workstation"),
		Floci:          getenv("FLOCI_CONTAINER", "infralab-floci"),
		KindCluster:    getenv("KIND_CLUSTER", "infralab"),
	}
	if cfg.Token == "" {
		log.Fatal("AGENT_TOKEN is required")
	}
	addr := getenv("AGENT_ADDR", ":7777")
	log.Printf("infra-agent %s listening on %s (origins: %v, workstation: %s, floci: %s)",
		version, addr, cfg.AllowedOrigins, cfg.Workstation, cfg.Floci)
	log.Fatal(http.ListenAndServe(addr, newHandler(cfg, execRunner{})))
}
