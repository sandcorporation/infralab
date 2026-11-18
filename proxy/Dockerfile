# infralab AI 프록시 이미지. 빌드: docker build proxy/  (저장소 루트에서, 문맥은 proxy/)
FROM golang:1.23.12-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-X main.version=${VERSION}" -o /proxy .

FROM alpine:3.21.10@sha256:bc21487101ae47172509130ee1092cc273a831968d64b617776d1f69c81e42ab
RUN apk add --no-cache ca-certificates && adduser -D -H -u 10001 proxy
COPY --from=build /proxy /usr/local/bin/infralab-proxy
USER proxy
EXPOSE 58090
ENTRYPOINT ["infralab-proxy"]
