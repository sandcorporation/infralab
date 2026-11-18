# syntax=docker/dockerfile:1
# e2e 전용 에이전트(scripts/ci.sh e2e) — 운영 이미지(agent/Dockerfile)와 같은 바이너리에 docker-cli·bash 만 얹는다.
# kind·kubectl 은 받지 않는다(e2e 시나리오는 kind·Floci 를 쓰지 않는다). 빌드 맥락은 저장소 루트다.
FROM golang:1.23.12-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f AS build
WORKDIR /src
COPY agent/go.mod agent/go.sum ./
RUN go mod download
COPY agent/*.go ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=e2e" -o /agent .

FROM alpine:3.21.10@sha256:bc21487101ae47172509130ee1092cc273a831968d64b617776d1f69c81e42ab
RUN apk add --no-cache docker-cli bash
COPY --from=build /agent /usr/local/bin/agent
COPY docker/agent-e2e/agentctl /usr/local/bin/agentctl
EXPOSE 7777
# 컨테이너는 스택과 함께 한 번만 뜨고, 에이전트 프로세스는 시험이 agentctl 로 토큰마다 띄운다(#227).
ENTRYPOINT ["sleep", "infinity"]
