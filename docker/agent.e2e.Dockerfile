# syntax=docker/dockerfile:1
# e2e 전용 에이전트(scripts/ci.sh e2e) — 운영 이미지(agent/Dockerfile)와 같은 바이너리에 docker-cli·bash 만 얹는다.
# kind·kubectl 은 받지 않는다(e2e 시나리오는 kind·Floci 를 쓰지 않는다). 빌드 맥락은 저장소 루트다.
FROM golang:1.27.4-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
WORKDIR /src
COPY agent/go.mod agent/go.sum ./
RUN go mod download
COPY agent/*.go ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=e2e" -o /agent .

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
RUN apk add --no-cache docker-cli bash
COPY --from=build /agent /usr/local/bin/agent
COPY docker/agent-e2e/agentctl /usr/local/bin/agentctl
EXPOSE 7777
# 컨테이너는 스택과 함께 한 번만 뜨고, 에이전트 프로세스는 시험이 agentctl 로 토큰마다 띄운다(#227).
ENTRYPOINT ["sleep", "infinity"]
