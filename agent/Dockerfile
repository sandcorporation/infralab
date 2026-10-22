FROM golang:1.23-alpine AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o /agent .

FROM alpine:3.21
RUN apk add --no-cache docker-cli bash curl ca-certificates
RUN curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 \
 && chmod +x /usr/local/bin/kind && kind version
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl && kubectl version --client
COPY --from=build /agent /usr/local/bin/agent
EXPOSE 7777
ENTRYPOINT ["agent"]
