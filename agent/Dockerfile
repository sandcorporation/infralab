FROM golang:1.23-alpine AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o /agent .

# linux/amd64·arm64 로 게시한다(image.yml, 아키텍처마다 네이티브 실행기). kind·kubectl 도 그 아키텍처 것을 받는다.
FROM alpine:3.21
ARG TARGETARCH
RUN apk add --no-cache docker-cli bash curl ca-certificates
RUN curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/latest/kind-linux-${TARGETARCH:-amd64} \
 && chmod +x /usr/local/bin/kind && kind version
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH:-amd64}/kubectl" \
 && chmod +x /usr/local/bin/kubectl && kubectl version --client
COPY --from=build /agent /usr/local/bin/agent
EXPOSE 7777
ENTRYPOINT ["agent"]
