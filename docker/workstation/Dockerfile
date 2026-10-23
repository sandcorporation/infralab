# 학생이 브라우저 터미널로 들어가는 작업용 컨테이너 — awscli·kubectl·terraform·node·claude·codex 가 미리 들어 있다.
# docker CLI 는 일부러 넣지 않는다 — docker 부재가 AI 의 호스트 우회 차단의 전부다.
FROM hashicorp/terraform:latest AS tf

FROM alpine:3.21
RUN apk add --no-cache bash aws-cli curl jq ca-certificates vim git nodejs npm
COPY --from=tf /bin/terraform /usr/local/bin/terraform
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl
# /root 는 compose 가 홈 볼륨으로 덮는다 — CLI 는 /usr/local 에 전역 설치한다.
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force
RUN printf 'export PS1="\[\e[32m\]lab\[\e[0m\]:\w\$ "\nalias k=kubectl\n' > /etc/profile.d/lab.sh
# 빌드 검증 — 하나라도 실행되지 않으면 빌드가 깨진다.
RUN node --version && claude --version && codex --version
WORKDIR /work
CMD ["sleep", "infinity"]
